local typedefs = require "kong.db.schema.typedefs"

return {
  name = "custom-rate-limiter",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { limit = { type = "integer", default = 100, required = true } },
          { window_size = { type = "integer", default = 60, required = true } },
          { max_violations = { type = "integer", default = 5, required = true } },
          { redis_host = { type = "string", default = "localhost", required = true } },
          { redis_port = { type = "integer", default = 6379, required = true } },
          { redis_password = { type = "string", default = null } },
          { redis_database = { type = "integer", default = 0 } },
          { redis_timeout = { type = "integer", default = 2000 } },
        },
    }},
  },
}