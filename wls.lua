local STATIC_DIR = "static"
local MAX_SIZE = 1024 * 1024
local MAX_CACHE_SIZE = 1024 * 128
local AF_INET = 2
local SOCK_STREAM = 1
local IPPROTO_TCP = 6
local SOMAXCONN = 0x7fffffff
local SOL_SOCKET = 0xFFFF
local SO_EXCLUSIVEADDRUSE = 0x000C
local SO_REUSEADDR = 0x0004
local TCP_NODELAY = 0x0001

local mime = require("mime")
local ffi = require("ffi")
ffi.cdef [[
  typedef uint16_t sa_family_t;
  typedef uint16_t in_port_t;
  typedef uint32_t in_addr_t;
  typedef int32_t  SOCKET;
  typedef uint16_t WORD;
  typedef uint32_t DWORD;

  typedef struct {
    WORD  wVersion;
    WORD  wHighVersion;
    char  szDescription[257];
    char  szSystemStatus[129];
    uint16_t iMaxSockets;
    uint16_t iMaxUdpDg;
    char *lpVendorInfo;
  } WSADATA;

  struct in_addr { in_addr_t s_addr; };
  struct sockaddr_in {
    sa_family_t    sin_family;
    in_port_t      sin_port;
    struct in_addr sin_addr;
    char           sin_zero[8];
  };
  struct sockaddr { sa_family_t sa_family; char sa_data[14]; };

  int WSAStartup(WORD wVersionRequested, WSADATA *lpWSAData);
  SOCKET socket(int af, int type, int protocol);
  int bind(SOCKET s, const struct sockaddr *addr, int namelen);
  int listen(SOCKET s, int backlog);
  SOCKET accept(SOCKET s, struct sockaddr *addr, int *addrlen);
  int recv(SOCKET s, void *buf, int len, int flags);
  int send(SOCKET s, const void *buf, int len, int flags);
  int closesocket(SOCKET s);
  unsigned short htons(unsigned short hostshort);
  unsigned long inet_addr(const char *cp);
  int setsockopt(SOCKET s, int level, int optname, const char *optval, int optlen);

  typedef struct {
    uint32_t dwFileAttributes;
    uint32_t ftCreationTime_dwLowDateTime;
    uint32_t ftCreationTime_dwHighDateTime;
    uint32_t ftLastAccessTime_dwLowDateTime;
    uint32_t ftLastAccessTime_dwHighDateTime;
    uint32_t ftLastWriteTime_dwLowDateTime;
    uint32_t ftLastWriteTime_dwHighDateTime;
    uint32_t nFileSizeHigh;
    uint32_t nFileSizeLow;
  } WIN32_FILE_ATTRIBUTE_DATA;
  int GetFileAttributesExA(const char *lpFileName, int fInfoLevelId,
                           WIN32_FILE_ATTRIBUTE_DATA *lpFileInformation);
]]
local ws2 = ffi.load("Ws2_32.dll")
local kernel = ffi.load("kernel32.dll")

local function get_file_size(path)
    local data = ffi.new("WIN32_FILE_ATTRIBUTE_DATA")
    if kernel.GetFileAttributesExA(path, 0, data) == 0 then
        return nil
    end
    return data.nFileSizeLow + data.nFileSizeHigh * 2 ^ 32
end

local function parse_request(raw)
    local req = {
        headers = {}
    }
    local sep = raw:find("\r\n\r\n", 1, true)
    local head = raw:sub(1, sep - 1)
    req.body = raw:sub(sep + 4)
    local lines = {}
    for line in head:gmatch("([^\r\n]+)") do
        lines[#lines + 1] = line
    end
    req.method, req.path = lines[1]:match("^(%u+)%s+([^%s]+)")
    for i = 2, #lines do
        local k, v = lines[i]:match("^(%S+):%s*(.*)$")
        if k then
            req.headers[k:lower()] = v
        end
    end
    return req
end

local function make_res(client)
    local status, headers, parts = 200, {
        ["Content-Type"] = "text/plain",
        ["Connection"] = "close",
        ["Server"] = "WLS - Walt's LuaJIT Server"
    }, {}
    local self
    self = {
        setStatus = function(_, s)
            status = s
            return self
        end,
        setHeader = function(_, k, v)
            headers[k] = v
            return self
        end,
        write = function(_, chunk)
            parts[#parts + 1] = chunk
            return self
        end,
        finish = function(_)
            local body = table.concat(parts)
            headers["Content-Length"] = tostring(#body)
            local lines = {"HTTP/1.1 " .. status .. " "}
            for k, v in pairs(headers) do
                lines[#lines + 1] = k .. ": " .. v
            end
            lines[#lines + 1] = ""
            lines[#lines + 1] = ""
            local resp = table.concat(lines, "\r\n") .. body
            ws2.send(client, resp, #resp, 0)
        end
    }
    self.h = self.setHeader
    self.s = self.setStatus
    self.w = self.write
    self.f = self.finish
    return self
end

local routes = {}

-- convert ":name" segments to Lua pattern
local function compile_pattern(path)
    local names = {}

    -- escape pattern magic
    local patt = path:gsub("([^%^%$%(%)%%.%[%]%+%-%?])", "%%%1")
    patt = patt:gsub(":([A-Za-z0-9_]+)", function(n)
        names[#names + 1] = n
        return "([^/]+)"
    end)

    return "^" .. patt .. "$", names
end

local function add_route(method, path, cb)
    method = method:upper()
    routes[method] = routes[method] or {
        exact = {},
        pattern = {}
    }

    if path:find(":") then -- parametric
        local regex, names = compile_pattern(path)
        table.insert(routes[method].pattern, {
            regex = regex,
            names = names,
            cb = cb
        })
    else -- literal
        routes[method].exact[path] = cb
    end
end

local manual_handler = nil
local router = {
    GET = function(p, cb)
        add_route("GET", p, cb)
    end,
    POST = function(p, cb)
        add_route("POST", p, cb)
    end,
    PUT = function(p, cb)
        add_route("PUT", p, cb)
    end,
    DELETE = function(p, cb)
        add_route("DELETE", p, cb)
    end,
    OPTIONS = function(p, cb)
        add_route("OPTIONS", p, cb)
    end,
    HANDLE = function(fn)
        local prev = manual_handler -- the chain we’ve built so far
        manual_handler = function(req, res, fallback)
            -- 'next' either runs the previous handler chain,
            -- or falls through to default_dispatch if there is none
            local function next()
                if prev then
                    return prev(req, res, fallback)
                else
                    return fallback(req, res)
                end
            end
            return fn(req, res, next)
        end
    end
}

-- match helper
local function find_route(method, path)
    local m = routes[method]
    if not m then
        return nil
    end

    local f = m.exact[path]
    if f then
        return f, {}
    end

    for _, r in ipairs(m.pattern) do
        local caps = {string.match(path, r.regex)}
        if #caps > 0 then
            local params = {}
            for i, name in ipairs(r.names) do
                params[name] = caps[i]
            end
            return r.cb, params
        end
    end
end
local cache = {}

local function default_dispatch(req, res)
    -- 1) try dynamic routes
    local cb, params = find_route(req.method, req.path)
    if cb then
        req.params = params
        return cb(req, res)
    end

    -- 2) static file
    local path = (req.path == "/" and "/index.html") or req.path
    local full = STATIC_DIR .. path
    local size = get_file_size(full)

    -- from cache?
    if cache[full] then
        return res:s(200):h("Content-Type", mime(full)):w(cache[full]):f()
    end

    local f = io.open(full, "rb")
    if f then
        local body = f:read("*all");
        f:close()

        if size and size > MAX_SIZE then
            return res:s(413):h("Content-Type", "text/plain"):w("413 File too large!\n"):f()
        end

        if size and size <= MAX_CACHE_SIZE then
            cache[full] = body
        end

        return res:s(200):h("Content-Type", mime(full)):w(body):f()
    end

    -- 3) not found
    res:s(404):h("Content-Type", "text/plain"):w("404 Not Found!\n"):f()
end

local function handle_request(req, res)
    if manual_handler then
        return manual_handler(req, res, default_dispatch) -- if manual handler decides not to handle the request, it will run default_dispatch
    end
    return default_dispatch(req, res)
end

local function start_server(address, port)
    assert(ws2.WSAStartup(0x202, ffi.new("WSADATA")) == 0)
    local srv = ws2.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    assert(srv ~= -1)

    local flag = ffi.new("int[1]", 1)
    if ws2.setsockopt(srv, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, ffi.cast("const char*", flag), ffi.sizeof(flag)) ~= 0 then
        assert(ws2.setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, ffi.cast("const char*", flag), ffi.sizeof(flag)) == 0)
    end
    assert(ws2.setsockopt(srv, IPPROTO_TCP, TCP_NODELAY, ffi.cast("const char*", flag), ffi.sizeof(flag)) == 0)

    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = AF_INET
    addr.sin_port = ws2.htons(port)
    addr.sin_addr.s_addr = ws2.inet_addr(address)
    assert(ws2.bind(srv, ffi.cast("const struct sockaddr*", addr), ffi.sizeof(addr)) == 0)
    assert(ws2.listen(srv, SOMAXCONN) == 0)

    print("Server running at http://" .. address .. ":" .. port)

    local buf = ffi.new("char[4096]")

    while true do
        local client = ws2.accept(srv, nil, nil)
        if client ~= -1 then
            local got = ws2.recv(client, buf, 4096, 0)
            if got > 0 then
                local req = parse_request(ffi.string(buf, got))
                local res = make_res(client)
                local ok, err = pcall(handle_request, req, res)
                if not ok then
                    ws2.send(client, "HTTP/1.1 500\r\n\r\n500 Internal Server Error:\r\n" .. err, #err, 0)
                end
            end
            ws2.closesocket(client)
        end
    end
end

local app = {
    start = function(self)
        return start_server(self.address, self.port)
    end,
    address = "0.0.0.0",
    port = 8080,
    config = function(self, conf)
        self.address = conf.address or self.address
        self.port = conf.port or self.port
        return self
    end,
    router = router
}

return app
