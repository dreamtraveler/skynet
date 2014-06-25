-- Copyright (C) 2012 Yichun Zhang (agentzh)
-- Copyright (C) 2014 Chang Feng
local socketchannel = require "socketchannel"
local bit = require "bit32"
local mysqlaux = require "mysqlaux.c"



local sub = string.sub
local strbyte = string.byte
local strchar = string.char
local strfind = string.find
local strrep = string.rep
local null = nil
local band = bit.band
local bxor = bit.bxor
local bor = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift
local sha1= mysqlaux.sha1_bin
local concat = table.concat
local unpack = unpack
local setmetatable = setmetatable
local error = error
local tonumber = tonumber
local    new_tab = function (narr, nrec) return {} end


local _M = { _VERSION = '0.13' }
-- constants

local STATE_CONNECTED = 1
local STATE_COMMAND_SENT = 2

local COM_QUERY = 0x03

local SERVER_MORE_RESULTS_EXISTS = 8

-- 16MB - 1, the default max allowed packet size used by libmysqlclient
local FULL_PACKET_SIZE = 16777215


local mt = { __index = _M }


-- mysql field value type converters
local converters = new_tab(0, 8)

for i = 0x01, 0x05 do
    -- tiny, short, long, float, double
    converters[i] = tonumber
end
-- converters[0x08] = tonumber  -- long long
converters[0x09] = tonumber  -- int24
converters[0x0d] = tonumber  -- year
converters[0xf6] = tonumber  -- newdecimal


local function _get_byte2(data, i)
    local a, b = strbyte(data, i, i + 1)
    return bor(a, lshift(b, 8)), i + 2
end


local function _get_byte3(data, i)
    local a, b, c = strbyte(data, i, i + 2)
    return bor(a, lshift(b, 8), lshift(c, 16)), i + 3
end


local function _get_byte4(data, i)
    local a, b, c, d = strbyte(data, i, i + 3)
    return bor(a, lshift(b, 8), lshift(c, 16), lshift(d, 24)), i + 4
end


local function _get_byte8(data, i)
    local a, b, c, d, e, f, g, h = strbyte(data, i, i + 7)

    -- XXX workaround for the lack of 64-bit support in bitop:
    local lo = bor(a, lshift(b, 8), lshift(c, 16), lshift(d, 24))
    local hi = bor(e, lshift(f, 8), lshift(g, 16), lshift(h, 24))
    return lo + hi * 4294967296, i + 8

    -- return bor(a, lshift(b, 8), lshift(c, 16), lshift(d, 24), lshift(e, 32),
               -- lshift(f, 40), lshift(g, 48), lshift(h, 56)), i + 8
end


local function _set_byte2(n)
    return strchar(band(n, 0xff), band(rshift(n, 8), 0xff))
end


local function _set_byte3(n)
    return strchar(band(n, 0xff),
                   band(rshift(n, 8), 0xff),
                   band(rshift(n, 16), 0xff))
end


local function _set_byte4(n)
    return strchar(band(n, 0xff),
                   band(rshift(n, 8), 0xff),
                   band(rshift(n, 16), 0xff),
                   band(rshift(n, 24), 0xff))
end


local function _from_cstring(data, i)
    local last = strfind(data, "\0", i, true)
    if not last then
        return nil, nil
    end

    return sub(data, i, last), last + 1
end


local function _to_cstring(data)
    return data .. "\0"
end


local function _to_binary_coded_string(data)
    return strchar(#data) .. data
end


local function _dump(data)
    local len = #data
    local bytes = new_tab(len, 0)
    for i = 1, len do
        bytes[i] = strbyte(data, i)
    end
    return concat(bytes, " ")
end



local function _dumphex(bytes)
    local result ={}

    for i = 1, string.len(bytes) do
        local charcode = tonumber(strbyte(bytes, i, i))
        local hexstr = string.format("%02X", charcode)
        result[i]=hexstr
    end

    local res=table.concat(result, " ")
    return res
end


local function _compute_token(password, scramble)
    if password == "" then
        return ""
    end
    --_dump(scramble)
    --print("password=",password)
    --print("password:", password, "scramble: ", _dumphex(scramble) )
    local stage1 = sha1(password)
    --print("stage1:", _dumphex(stage1) )
    local stage2 = sha1(stage1)
    --print("stage2:", _dumphex(stage2) )
    local stage3 = sha1(scramble .. stage2)
    --print("stage3:", _dumphex(stage3) )
    local n = #stage1
    local bytes = new_tab(n, 0)
    for i = 1, n do
         bytes[i] = strchar(bxor(strbyte(stage3, i), strbyte(stage1, i)))
    end

    return concat(bytes)
end

local function _compose_packet(self, req, size)
   self.packet_no = self.packet_no + 1

    local packet = _set_byte3(size) .. strchar(self.packet_no) .. req
    return packet
end


local function _send_packet(self, req, size)
    local sock = self.sock

    self.packet_no = self.packet_no + 1

    --print("packet no: ", self.packet_no)

    local packet = _set_byte3(size) .. strchar(self.packet_no) .. req

    --print("sending packet...")

    --return sock:send(packet)
    return socket.write(self.sock,packet)
end


local function _recv_packet(self,sock)


    local data = sock:read( 4)
    if not data then
        return nil, nil, "failed to receive packet header: " 
    end
	--print("_recv_packet data type:" ,type(data) )
    --print("packet header: ", _dump(data))

    local len, pos = _get_byte3(data, 1)

    --print("recv_packet packet length: ", len)

    if len == 0 then
        return nil, nil, "empty packet"
    end

    if len > self._max_packet_size then
        return nil, nil, "packet size too big: " .. len
    end

    local num = strbyte(data, pos)

    --print("recv packet: packet no: ", num)

    self.packet_no = num

    --data, err = sock:receive(len)

    data = sock:read(len)
    
 
    if not data then
        return nil, nil, "failed to read packet content: " 
    end

    --print("packet content: ", _dump(data))
    --print("packet content (ascii): ", data)

    local field_count = strbyte(data, 1)
	--print("field count:",field_count)
    local typ
    if field_count == 0x00 then
        typ = "OK"
    elseif field_count == 0xff then
        typ = "ERR"
    elseif field_count == 0xfe then
        typ = "EOF"
    elseif field_count <= 250 then
        typ = "DATA"
    end
	
    --print("recv packet: typ= ", typ)
    return data, typ
end


local function _from_length_coded_bin(data, pos)
    local first = strbyte(data, pos)

    --print("LCB: first: ", first)

    if not first then
        return nil, pos
    end

    if first >= 0 and first <= 250 then
        return first, pos + 1
    end

    if first == 251 then
        return null, pos + 1
    end

    if first == 252 then
        pos = pos + 1
        return _get_byte2(data, pos)
    end

    if first == 253 then
        pos = pos + 1
        return _get_byte3(data, pos)
    end

    if first == 254 then
        pos = pos + 1
        return _get_byte8(data, pos)
    end

    return false, pos + 1
end


local function _from_length_coded_str(data, pos)
    local len
    len, pos = _from_length_coded_bin(data, pos)
    if len == nil or len == null then
        return null, pos
    end

    return sub(data, pos, pos + len - 1), pos + len
end


local function _parse_ok_packet(packet)
    local res = new_tab(0, 5)
    local pos

    res.affected_rows, pos = _from_length_coded_bin(packet, 2)

    --print("affected rows: ", res.affected_rows, ", pos:", pos)

    res.insert_id, pos = _from_length_coded_bin(packet, pos)

    --print("insert id: ", res.insert_id, ", pos:", pos)

    res.server_status, pos = _get_byte2(packet, pos)

    --print("server status: ", res.server_status, ", pos:", pos)

    res.warning_count, pos = _get_byte2(packet, pos)

    --print("warning count: ", res.warning_count, ", pos: ", pos)

    local message = sub(packet, pos)
    if message and message ~= "" then
        res.message = message
    end

    --print("message: ", res.message, ", pos:", pos)

    return res
end


local function _parse_eof_packet(packet)
    local pos = 2

    local warning_count, pos = _get_byte2(packet, pos)
    local status_flags = _get_byte2(packet, pos)

    return warning_count, status_flags
end


local function _parse_err_packet(packet)
    local errno, pos = _get_byte2(packet, 2)
    local marker = sub(packet, pos, pos)
    local sqlstate
    if marker == '#' then
        -- with sqlstate
        pos = pos + 1
        sqlstate = sub(packet, pos, pos + 5 - 1)
        pos = pos + 5
    end

    local message = sub(packet, pos)
    return errno, message, sqlstate
end


local function _parse_result_set_header_packet(packet)
    local field_count, pos = _from_length_coded_bin(packet, 1)

    local extra
    extra = _from_length_coded_bin(packet, pos)

    return field_count, extra
end


local function _parse_field_packet(data)
    local col = new_tab(0, 2)
    local catalog, db, table, orig_table, orig_name, charsetnr, length
    local pos
    catalog, pos = _from_length_coded_str(data, 1)

    --print("catalog: ", col.catalog, ", pos:", pos)

    db, pos = _from_length_coded_str(data, pos)
    table, pos = _from_length_coded_str(data, pos)
    orig_table, pos = _from_length_coded_str(data, pos)
    col.name, pos = _from_length_coded_str(data, pos)

    orig_name, pos = _from_length_coded_str(data, pos)

    pos = pos + 1 -- ignore the filler

    charsetnr, pos = _get_byte2(data, pos)

    length, pos = _get_byte4(data, pos)

    col.type = strbyte(data, pos)

    --[[
    pos = pos + 1

    col.flags, pos = _get_byte2(data, pos)

    col.decimals = strbyte(data, pos)
    pos = pos + 1

    local default = sub(data, pos + 2)
    if default and default ~= "" then
        col.default = default
    end
    --]]

    return col
end


local function _parse_row_data_packet(data, cols, compact)
    local pos = 1
    local ncols = #cols
    local row
    if compact then
        row = new_tab(ncols, 0)
    else
        row = new_tab(0, ncols)
    end
    for i = 1, ncols do
        local value
        value, pos = _from_length_coded_str(data, pos)
        local col = cols[i]
        local typ = col.type
        local name = col.name

        --print("row field value: ", value, ", type: ", typ)

        if value ~= null then
            local conv = converters[typ]
            if conv then
                value = conv(value)
            end
        end

        if compact then
            row[i] = value

        else
            row[name] = value
        end
    end

    return row
end


local function _recv_field_packet(self, sock)
    local packet, typ, err = _recv_packet(self, sock)
    if not packet then
        return nil, err
    end

    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        return nil, msg, errno, sqlstate
    end

    if typ ~= 'DATA' then
        return nil, "bad field packet type: " .. typ
    end

    -- typ == 'DATA'

    return _parse_field_packet(packet)
end

local function _recv_decode_packet_resp(self)
     return function(sock)
        return true, _recv_packet(self,sock)
    end
end

local function _recv_auth_resp(self)
     return function(sock)
        --print("recv auth resp")
        local packet, typ, err = _recv_packet(self,sock)
        if not packet then
            --print("recv auth resp : failed to receive the result packet")
            error ("failed to receive the result packet"..err)
        end
        
        --print("receive auth response packet type: ",typ)
        if typ == 'ERR' then
            local errno, msg, sqlstate = _parse_err_packet(packet)
            error( string.format("errno:%d, msg:%s,sqlstate:%s",errno,msg,sqlstate))
        end

        if typ == 'EOF' then
            error "old pre-4.1 authentication protocol not supported"
        end

        if typ ~= 'OK' then
            error "bad packet type: " 
        end
        return true, true
    end
end


local function _mysql_login(self,user,password,database)
    
    return function(sockchannel)
          local packet, typ, err =   sockchannel:response( _recv_decode_packet_resp(self) )
        --local aat={}
        if not packet then
            error(  err )
        end

        if typ == "ERR" then
            local errno, msg, sqlstate = _parse_err_packet(packet)
            error( string.format("errno:%d, msg:%s,sqlstate:%s",errno,msg,sqlstate))
        end

        self.protocol_ver = strbyte(packet)

        --print("protocol version: ", self.protocol_ver)

        local server_ver, pos = _from_cstring(packet, 2)
        if not server_ver then
            error "bad handshake initialization packet: bad server version"
        end
        
        --print("server version: ", server_ver)

        self._server_ver = server_ver

        
        local thread_id, pos = _get_byte4(packet, pos)

        --print("thread id: ", thread_id)

        local scramble1 = sub(packet, pos, pos + 8 - 1)
        --print("scramble1:",_dump(scramble1), "pos:",pos)
        if not scramble1 then
            error "1st part of scramble not found"
        end

        pos = pos + 9 -- skip filler

        -- two lower bytes
        self._server_capabilities, pos = _get_byte2(packet, pos)

        --print("server capabilities: ", self._server_capabilities)

        self._server_lang = strbyte(packet, pos)
        pos = pos + 1

        --print("server lang: ", self._server_lang)

        self._server_status, pos = _get_byte2(packet, pos)

        --print("server status: ", self._server_status)

        local more_capabilities
        more_capabilities, pos = _get_byte2(packet, pos)

        self._server_capabilities = bor(self._server_capabilities,
                                        lshift(more_capabilities, 16))

        --print("server capabilities: ", self._server_capabilities)

        
        -- local len = strbyte(packet, pos)
        local len = 21 - 8 - 1

        --print("scramble len: ", len)

        pos = pos + 1 + 10

        local scramble_part2 = sub(packet, pos, pos + len - 1)
        if not scramble_part2 then
            error "2nd part of scramble not found"
        end
        

        local scramble = scramble1..scramble_part2
        --print("scramble:",_dump(scramble) )
        local token = _compute_token(password, scramble)

        -- local client_flags = self._server_capabilities
        local client_flags = 260047;

        --print("token: ", _dump(token))

        local req = _set_byte4(client_flags)
                    .. _set_byte4(self._max_packet_size)
                    .. "\0" -- TODO: add support for charset encoding
                    .. strrep("\0", 23)
                    .. _to_cstring(user)
                    .. _to_binary_coded_string(token)
                    .. _to_cstring(database)

        local packet_len = 4 + 4 + 1 + 23 + #user + 1
            + #token + 1 + #database + 1

         --print("packet content length: ", packet_len)
         --print("packet content: ", _dump(concat(req, "")))

        local authpacket=_compose_packet(self,req,packet_len)
        --print("mysql login authpacket len=",#authpacket)
        return sockchannel:request(authpacket,_recv_auth_resp(self))
    end
end


local function _compose_query(self, query)
 
    self.packet_no = -1

    local cmd_packet = strchar(COM_QUERY) .. query
    local packet_len = 1 + #query

    local querypacket = _compose_packet(self, cmd_packet, packet_len)
    --print("compose query packet, len= ", #querypacket)
    return querypacket
end



local function read_result(self, sock)
    --print("read_result")
    local packet, typ, err = _recv_packet(self, sock)
    if not packet then
        --print("read result", err)
        return nil, err
        --error( err )
    end

    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        --print("read result ", msg, errno, sqlstate)
        return nil, msg, errno, sqlstate
        --error( string.format("errno:%d, msg:%s,sqlstate:%s",errno,msg,sqlstate))
    end

    if typ == 'OK' then
        local res = _parse_ok_packet(packet)
        if res and band(res.server_status, SERVER_MORE_RESULTS_EXISTS) ~= 0 then
            --print("read result ", res, "again")
            return res, "again"
        end
        --print("parse ok packet res=",res)
        return res
    end

    if typ ~= 'DATA' then
        --print("read result", "packet type " ,typ , " not supported")
        return nil, "packet type " .. typ .. " not supported"
        --error( "packet type " .. typ .. " not supported" )
    end

    -- typ == 'DATA'

    --print("read the result set header packet")

    local field_count, extra = _parse_result_set_header_packet(packet)

    --print("field count: ", field_count)

    local cols = new_tab(field_count, 0)
    for i = 1, field_count do
        local col, err, errno, sqlstate = _recv_field_packet(self, sock)
        if not col then
            return nil, err, errno, sqlstate
            --error( string.format("errno:%d, msg:%s,sqlstate:%s",errno,msg,sqlstate))
        end

        cols[i] = col
    end

    local packet, typ, err = _recv_packet(self, sock)
    if not packet then
        --error( err)
        return nil, err
    end

    if typ ~= 'EOF' then
        --error ( "unexpected packet type " .. typ .. " while eof packet is ".. "expected" )
        return nil, "unexpected packet type " .. typ .. " while eof packet is ".. "expected" 
    end

    -- typ == 'EOF'

    local compact = self.compact

    local rows = new_tab( 4, 0)
    local i = 0
    while true do
        --print("reading a row")

        packet, typ, err = _recv_packet(self, sock)
        if not packet then
            --error (err)
            return nil, err
        end

        if typ == 'EOF' then
            local warning_count, status_flags = _parse_eof_packet(packet)

            --print("status flags: ", status_flags)

            if band(status_flags, SERVER_MORE_RESULTS_EXISTS) ~= 0 then
                return rows, "again"
            end

            break
        end

        -- if typ ~= 'DATA' then
            -- return nil, 'bad row packet type: ' .. typ
        -- end

        -- typ == 'DATA'

        local row = _parse_row_data_packet(packet, cols, compact)
        i = i + 1
        rows[i] = row
    end

    return rows
end

local function _query_resp(self)
     return function(sock)
        --return true ,read_result(self,sock)
        --local res, more = read_result(self,sock)
        local res, err, errno, sqlstate = read_result(self,sock)
        if not res then
            local badresult ={}
            badresult.badresult = true
            badresult.err = err
            badresult.errno = errno
            badresult.sqlstate = sqlstate
            return true , badresult
        end
        if err ~= "again" then
            return true, res
        end
        local mulitresultset = {res}
        mulitresultset.mulitresultset = true
        local i =2
        while err =="again" do
            --res, more = read_result(self,sock)
            res, err, errno, sqlstate = read_result(self,sock)
            if not res then
                return true, mulitresultset
            end
            mulitresultset[i]=res
            i=i+1
        end
        return true, mulitresultset
    end
end

function _M.connect( opts)

    local self = setmetatable( {}, mt)

    local max_packet_size = opts.max_packet_size
    if not max_packet_size then
        max_packet_size = 1024 * 1024 -- default 1 MB
    end
    self._max_packet_size = max_packet_size
    self.compact = opts.compact_arrays


    local database = opts.database or ""
    local user = opts.user or ""
    local password = opts.password or ""

    local channel = socketchannel.channel {
        host = opts.host,
        port = opts.port or 3306,
        auth = _mysql_login(self,user,password,database ),
    }
    -- try connect first only once
    channel:connect(true)
    self.sockchannel = channel


    return self
end



function _M.disconnect(self)
    self.sockchannel:close()
    setmetatable(self, nil)
end


function _M.query(self, query)
    local querypacket = _compose_query(self, query)
    local sockchannel = self.sockchannel
    if not self.query_resp then
        self.query_resp = _query_resp(self)
    end
    return  sockchannel:request( querypacket, self.query_resp )
end

function _M.server_ver(self)
    return self._server_ver
end


function _M.quote_sql_str( str)
    return mysqlaux.quote_sql_str(str)
end

function _M.set_compact_arrays(self, value)
    self.compact = value
end


return _M
