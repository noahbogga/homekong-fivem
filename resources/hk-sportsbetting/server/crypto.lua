-- Pure Lua SHA-256 + HMAC-SHA256 implementation for FiveM
-- Used by the Provably Fair system to generate verifiable game outcomes

local band, bor, bxor, bnot, rshift, lshift
if bit32 then
    band, bor, bxor, bnot, rshift, lshift = bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.rshift, bit32.lshift
else
    band  = function(a, b) return a & b end
    bor   = function(a, b) return a | b end
    bxor  = function(a, b, c)
        if c then return (a ~ b) ~ c end
        return a ~ b
    end
    bnot  = function(a) return ~a & 0xFFFFFFFF end
    rshift = function(a, n) return (a >> n) & 0xFFFFFFFF end
    lshift = function(a, n) return (a << n) & 0xFFFFFFFF end
end

local function rrotate(x, n)
    x = band(x, 0xFFFFFFFF)
    return bor(rshift(x, n), lshift(x, 32 - n))
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function preprocess(msg)
    local len = #msg
    local bits = len * 8
    msg = msg .. "\128"
    local pad = (56 - (#msg % 64)) % 64
    msg = msg .. string.rep("\0", pad)
    msg = msg .. string.char(
        0, 0, 0, 0,
        band(rshift(bits, 24), 0xFF),
        band(rshift(bits, 16), 0xFF),
        band(rshift(bits, 8), 0xFF),
        band(bits, 0xFF)
    )
    return msg
end

local function sha256_raw(msg)
    msg = preprocess(msg)

    local h0 = 0x6a09e667
    local h1 = 0xbb67ae85
    local h2 = 0x3c6ef372
    local h3 = 0xa54ff53a
    local h4 = 0x510e527f
    local h5 = 0x9b05688c
    local h6 = 0x1f83d9ab
    local h7 = 0x5be0cd19

    for i = 1, #msg, 64 do
        local W = {}
        for j = 1, 16 do
            local offset = i + (j - 1) * 4
            local b1, b2, b3, b4 = string.byte(msg, offset, offset + 3)
            W[j] = lshift(b1, 24) + lshift(b2, 16) + lshift(b3, 8) + b4
        end

        for j = 17, 64 do
            local s0 = bxor(rrotate(W[j-15], 7), rrotate(W[j-15], 18), rshift(W[j-15], 3))
            local s1 = bxor(rrotate(W[j-2], 17), rrotate(W[j-2], 19), rshift(W[j-2], 10))
            W[j] = band(W[j-16] + s0 + W[j-7] + s1, 0xFFFFFFFF)
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7

        for j = 1, 64 do
            local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = band(h + S1 + ch + K[j] + W[j], 0xFFFFFFFF)
            local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = band(S0 + maj, 0xFFFFFFFF)

            h = g
            g = f
            f = e
            e = band(d + temp1, 0xFFFFFFFF)
            d = c
            c = b
            b = a
            a = band(temp1 + temp2, 0xFFFFFFFF)
        end

        h0 = band(h0 + a, 0xFFFFFFFF)
        h1 = band(h1 + b, 0xFFFFFFFF)
        h2 = band(h2 + c, 0xFFFFFFFF)
        h3 = band(h3 + d, 0xFFFFFFFF)
        h4 = band(h4 + e, 0xFFFFFFFF)
        h5 = band(h5 + f, 0xFFFFFFFF)
        h6 = band(h6 + g, 0xFFFFFFFF)
        h7 = band(h7 + h, 0xFFFFFFFF)
    end

    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

local function sha256_bytes(msg)
    msg = preprocess(msg)

    local h0 = 0x6a09e667
    local h1 = 0xbb67ae85
    local h2 = 0x3c6ef372
    local h3 = 0xa54ff53a
    local h4 = 0x510e527f
    local h5 = 0x9b05688c
    local h6 = 0x1f83d9ab
    local h7 = 0x5be0cd19

    for i = 1, #msg, 64 do
        local W = {}
        for j = 1, 16 do
            local offset = i + (j - 1) * 4
            local b1, b2, b3, b4 = string.byte(msg, offset, offset + 3)
            W[j] = lshift(b1, 24) + lshift(b2, 16) + lshift(b3, 8) + b4
        end
        for j = 17, 64 do
            local s0 = bxor(rrotate(W[j-15], 7), rrotate(W[j-15], 18), rshift(W[j-15], 3))
            local s1 = bxor(rrotate(W[j-2], 17), rrotate(W[j-2], 19), rshift(W[j-2], 10))
            W[j] = band(W[j-16] + s0 + W[j-7] + s1, 0xFFFFFFFF)
        end
        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for j = 1, 64 do
            local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = band(h + S1 + ch + K[j] + W[j], 0xFFFFFFFF)
            local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = band(S0 + maj, 0xFFFFFFFF)
            h = g; g = f; f = e
            e = band(d + temp1, 0xFFFFFFFF)
            d = c; c = b; b = a
            a = band(temp1 + temp2, 0xFFFFFFFF)
        end
        h0 = band(h0 + a, 0xFFFFFFFF)
        h1 = band(h1 + b, 0xFFFFFFFF)
        h2 = band(h2 + c, 0xFFFFFFFF)
        h3 = band(h3 + d, 0xFFFFFFFF)
        h4 = band(h4 + e, 0xFFFFFFFF)
        h5 = band(h5 + f, 0xFFFFFFFF)
        h6 = band(h6 + g, 0xFFFFFFFF)
        h7 = band(h7 + h, 0xFFFFFFFF)
    end

    local result = ""
    for _, v in ipairs({h0, h1, h2, h3, h4, h5, h6, h7}) do
        result = result .. string.char(
            band(rshift(v, 24), 0xFF),
            band(rshift(v, 16), 0xFF),
            band(rshift(v, 8), 0xFF),
            band(v, 0xFF)
        )
    end
    return result
end

local function hmac_sha256(key, message)
    local blockSize = 64
    if #key > blockSize then
        key = sha256_bytes(key)
    end
    if #key < blockSize then
        key = key .. string.rep("\0", blockSize - #key)
    end

    local opad = ""
    local ipad = ""
    for i = 1, blockSize do
        local kb = string.byte(key, i)
        opad = opad .. string.char(bxor(kb, 0x5c))
        ipad = ipad .. string.char(bxor(kb, 0x36))
    end

    local inner = sha256_bytes(ipad .. message)
    return sha256_raw(opad .. inner)
end

-- Convert hex hash to a float [0, 1) using first 4 bytes
local function hashToFloat(hash, offset)
    offset = offset or 0
    local idx = (offset * 8) + 1
    local hex4 = hash:sub(idx, idx + 7)
    local num = tonumber(hex4, 16)
    return num / 0x100000000
end

-- Generate multiple floats from a single HMAC result (up to 8 floats per 32-byte hash)
local function hashToFloats(hash, count)
    local floats = {}
    for i = 0, count - 1 do
        if i < 8 then
            floats[#floats + 1] = hashToFloat(hash, i)
        else
            -- Chain: hash the hash for more bytes
            hash = sha256_raw(hash)
            floats[#floats + 1] = hashToFloat(hash, 0)
        end
    end
    return floats
end

-- Exports
Crypto = {
    sha256 = sha256_raw,
    hmac_sha256 = hmac_sha256,
    hashToFloat = hashToFloat,
    hashToFloats = hashToFloats,
}

-- Generate a game hash from server seed, client seed, nonce, and optional cursor
function Crypto.generateGameHash(serverSeed, clientSeed, nonce, cursor)
    cursor = cursor or 0
    local message = clientSeed .. ":" .. tostring(nonce) .. ":" .. tostring(cursor)
    return hmac_sha256(serverSeed, message)
end

-- Generate a random seed (64 hex chars) using /dev/urandom
function Crypto.generateSeed()
    local f = io.open('/dev/urandom', 'rb')
    if f then
        local bytes = f:read(32)
        f:close()
        if bytes and #bytes == 32 then
            local hex = ''
            for i = 1, #bytes do
                hex = hex .. string.format('%02x', string.byte(bytes, i))
            end
            return hex
        end
    end
    -- Fallback (should never hit on Linux)
    local chars = 'abcdef0123456789'
    local seed = ''
    for i = 1, 64 do
        local idx = math.random(1, #chars)
        seed = seed .. chars:sub(idx, idx)
    end
    return seed
end
