local schema_topological_sort = require "kong.db.schema.topological_sort"
local protobuf = require "kong.tools.protobuf"
local lyaml = require "lyaml"


local setmetatable = setmetatable
local assert = assert
local type = type
local pcall = pcall
local pairs = pairs
local ipairs = ipairs
local insert = table.insert
local io_open = io.open
local null = ngx.null


local REMOVE_FIRST_LINE_PATTERN = "^[^\n]+\n(.+)$"
local GLOBAL_QUERY_OPTS = { nulls = true, workspace = null }
local TOPOLOGICALLY_SORTED_SCHEMA_NAMES = {}
local FOREIGN_KEY_NAMES = {}


local function convert_nulls(tbl, from, to)
  for k,v in pairs(tbl) do
    if v == from then
      tbl[k] = to

    elseif type(v) == "table" then
      tbl[k] = convert_nulls(v, from, to)
    end
  end

  return tbl
end


local function to_yaml_string(tbl)
  convert_nulls(tbl, null, lyaml.null)
  local pok, yaml, err = pcall(lyaml.dump, { tbl })
  if not pok then
    return nil, yaml
  end
  if not yaml then
    return nil, err
  end

  -- drop the multi-document "---\n" header and "\n..." trailer
  return yaml:sub(5, -5)
end


local function to_yaml_file(entities, filename)
  local yaml, err = to_yaml_string(entities)
  if not yaml then
    return nil, err
  end

  local fd, err = io_open(filename, "w")
  if not fd then
    return nil, err
  end

  local ok, err = fd:write(yaml)
  if not ok then
    return nil, err
  end

  fd:close()

  return true
end


local function get_foreign_key_names(name)
  if FOREIGN_KEY_NAMES[name] then
    return FOREIGN_KEY_NAMES[name]
  end

  local dao = kong.db.daos[name]
  if not dao then
    kong.log.err("unable to find dao with name '", name, "'")
    return {}
  end

  local schema = dao.schema

  local fks = {}
  for field_name, field in schema:each_field() do
    if field.type == "foreign" then
      insert(fks, field_name)
    end
  end

  FOREIGN_KEY_NAMES[name] = fks

  return fks
end


local function get_topologically_sorted_schema_names(skip_ws)
  if type(skip_ws) ~= "boolean" then
    skip_ws = true
  end

  if TOPOLOGICALLY_SORTED_SCHEMA_NAMES[skip_ws] then
    return TOPOLOGICALLY_SORTED_SCHEMA_NAMES[skip_ws]
  end

  local schemas = {}
  for _, dao in pairs(kong.db.daos) do
    local schema = dao.schema
    if schema.db_export == false or (skip_ws and schema.name == "workspaces") then
      goto continue
    end

    insert(schemas, schema)

    ::continue::
  end

  local schemas, err = schema_topological_sort(schemas)
  if not schemas then
    kong.log.err("topological sort of schemas failed (", err, ")")
    return {}
  end

  for i, schema in ipairs(schemas) do
    schemas[i] = schema.name
  end

  TOPOLOGICALLY_SORTED_SCHEMA_NAMES[skip_ws] = schemas

  return schemas
end


local function begin_transaction(db)
  if db.strategy == "postgres" then
    local ok, err = db.connector:connect("read")
    if not ok then
      return nil, err
    end

    ok, err = db.connector:query("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;", "read")
    if not ok then
      return nil, err
    end
  end

  return true
end


local function end_transaction(db)
  if db.strategy == "postgres" then
    -- just finish up the read-only transaction,
    -- either COMMIT or ROLLBACK is fine.
    db.connector:query("ROLLBACK;", "read")
    db.connector:setkeepalive()
  end
end


local function export_from_db_impl(emitter, skip_ws, skip_disabled_entities, expand_foreigns)
  local db = kong.db
  local daos = db.daos
  local ok, err = begin_transaction(db)
  if not ok then
    return nil, err
  end

  emitter:emit_toplevel({
    _format_version = "3.0",
    _transform = false,
  })

  local schema_names = get_topologically_sorted_schema_names(skip_ws)
  local plugins_configured = {}
  local disabled_services = {}
  local disabled_routes = {}
  for _, name in ipairs(schema_names) do
    local fks = get_foreign_key_names(name)
    local page_size
    if daos[name].pagination then
      page_size = daos[name].pagination.max_page_size
    end
    for row, err in daos[name]:each_for_export(page_size, GLOBAL_QUERY_OPTS) do
      if not row then
        end_transaction(db)
        kong.log.err(err)
        return nil, err
      end

      -- do not export disabled services and disabled plugins when skip_disabled_entities
      -- as well do not export plugins and routes of disabled services
      if skip_disabled_entities and name == "services" and not row.enabled then
        disabled_services[row.id] = true

      elseif skip_disabled_entities and name == "routes" and row.service and
        disabled_services[row.service ~= null and row.service.id] then
          disabled_routes[row.id] = true

      elseif skip_disabled_entities and name == "plugins" and not row.enabled then
        goto skip_emit

      else
        for _, foreign_name in ipairs(fks) do
          if type(row[foreign_name]) == "table" then
            local id = row[foreign_name].id
            if id ~= nil then
              if disabled_services[id] or disabled_routes[id] then
                goto skip_emit
              end
              if not expand_foreigns then
                row[foreign_name] = id
              end
            end
          end
        end

        if name == "plugins" then
          plugins_configured[row.name] = true
        end

        emitter:emit_entity(name, row)
      end
      ::skip_emit::
    end
  end

  end_transaction(db)

  return (emitter:done()), nil, plugins_configured
end


local fd_emitter = {
  emit_toplevel = function(self, tbl)
    self.fd:write(to_yaml_string(tbl))
  end,

  emit_entity = function(self, entity_name, entity_data)
    local yaml = to_yaml_string({ [entity_name] = { entity_data } })
    if entity_name == self.current_entity then
      yaml = assert(yaml:match(REMOVE_FIRST_LINE_PATTERN))
    end
    self.fd:write(yaml)
    self.current_entity = entity_name
  end,

  done = function()
    return true
  end,
}


function fd_emitter.new(fd)
  return setmetatable({ fd = fd }, { __index = fd_emitter })
end


local function export_from_db(fd, skip_ws, skip_disabled_entities)
  -- not sure if this really useful for skip_ws,
  -- but I want to allow skip_disabled_entities and would rather have consistent interface
  if skip_ws == nil then
    skip_ws = true
  end

  if skip_disabled_entities == nil then
    skip_disabled_entities = false
  end

  return export_from_db_impl(fd_emitter.new(fd), skip_ws, skip_disabled_entities, false)
end


local table_emitter = {
  emit_toplevel = function(self, tbl)
    self.out = tbl
  end,

  emit_entity = function(self, entity_name, entity_data)
    if not self.out[entity_name] then
      self.out[entity_name] = { entity_data }

    else
      insert(self.out[entity_name], entity_data)
    end
  end,

  done = function(self)
    return self.out
  end,
}


function table_emitter.new()
  return setmetatable({}, { __index = table_emitter })
end


local function export()
  return export_from_db_impl(table_emitter.new(), true, true, false)
end


local function export_config(skip_ws, skip_disabled_entities)
  -- default skip_ws=false and skip_disabled_services=true
  if skip_ws == nil then
    skip_ws = false
  end

  if skip_disabled_entities == nil then
    skip_disabled_entities = true
  end

  return export_from_db_impl(table_emitter.new(), skip_ws, skip_disabled_entities, false)
end


local function remove_nulls(tbl)
  for k,v in pairs(tbl) do
    if v == null then
      tbl[k] = nil

    elseif type(v) == "table" then
      tbl[k] = remove_nulls(v)
    end
  end
  return tbl
end


local proto_emitter = {
  emit_toplevel = function(self, tbl)
    self.out = {
      format_version = tbl._format_version,
    }
  end,

  emit_entity = function(self, entity_name, entity_data)
    if entity_name == "plugins" then
      entity_data.config = protobuf.pbwrap_struct(entity_data.config)
    end

    if not self.out[entity_name] then
      self.out[entity_name] = { entity_data }

    else
      insert(self.out[entity_name], entity_data)
    end
  end,

  done = function(self)
    return remove_nulls(self.out)
  end,
}


function proto_emitter.new()
  return setmetatable({}, { __index = proto_emitter })
end


local function export_config_proto(skip_ws, skip_disabled_entities)
  -- default skip_ws=false and skip_disabled_services=true
  if skip_ws == nil then
    skip_ws = false
  end

  if skip_disabled_entities == nil then
    skip_disabled_entities = true
  end

  return export_from_db_impl(proto_emitter.new(), skip_ws, skip_disabled_entities, true)
end


local function sanitize_output(entities)
  entities.workspaces = nil

  for _, s in pairs(entities) do -- set of entities
    for _, e in pairs(s) do -- individual entity
      e.ws_id = nil
    end
  end
end


return {
  convert_nulls = convert_nulls,
  to_yaml_string = to_yaml_string,
  to_yaml_file = to_yaml_file,

  export = export,
  export_from_db = export_from_db,
  export_config = export_config,
  export_config_proto = export_config_proto,

  sanitize_output = sanitize_output,

  get_topologically_sorted_schema_names = get_topologically_sorted_schema_names,
}
