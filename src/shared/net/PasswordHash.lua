--!strict
-- src/shared/net/PasswordHash.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure-Luau FIPS 180-4 SHA-256 and salted password hashing for server-side lobby verification.

local K = {
	0x428a2f98,
	0x71374491,
	0xb5c0fbcf,
	0xe9b5dba5,
	0x3956c25b,
	0x59f111f1,
	0x923f82a4,
	0xab1c5ed5,
	0xd807aa98,
	0x12835b01,
	0x243185be,
	0x550c7dc3,
	0x72be5d74,
	0x80deb1fe,
	0x9bdc06a7,
	0xc19bf174,
	0xe49b69c1,
	0xefbe4786,
	0x0fc19dc6,
	0x240ca1cc,
	0x2de92c6f,
	0x4a7484aa,
	0x5cb0a9dc,
	0x76f988da,
	0x983e5152,
	0xa831c66d,
	0xb00327c8,
	0xbf597fc7,
	0xc6e00bf3,
	0xd5a79147,
	0x06ca6351,
	0x14292967,
	0x27b70a85,
	0x2e1b2138,
	0x4d2c6dfc,
	0x53380d13,
	0x650a7354,
	0x766a0abb,
	0x81c2c92e,
	0x92722c85,
	0xa2bfe8a1,
	0xa81a664b,
	0xc24b8b70,
	0xc76c51a3,
	0xd192e819,
	0xd6990624,
	0xf40e3585,
	0x106aa070,
	0x19a4c116,
	0x1e376c08,
	0x2748774c,
	0x34b0bcb5,
	0x391c0cb3,
	0x4ed8aa4a,
	0x5b9cca4f,
	0x682e6ff3,
	0x748f82ee,
	0x78a5636f,
	0x84c87814,
	0x8cc70208,
	0x90befffa,
	0xa4506ceb,
	0xbef9a3f7,
	0xc67178f2,
}

local PasswordHash = {}

function PasswordHash.sha256Hex(msg: string): string
	local len = #msg
	local padLen = (55 - len) % 64
	local bitLen = len * 8
	local padded = msg
		.. "\128"
		.. string.rep("\0", padLen)
		.. string.char(
			bit32.band(math.floor(bitLen / 2 ^ 56), 0xff),
			bit32.band(math.floor(bitLen / 2 ^ 48), 0xff),
			bit32.band(math.floor(bitLen / 2 ^ 40), 0xff),
			bit32.band(math.floor(bitLen / 2 ^ 32), 0xff),
			bit32.band(bit32.rshift(bitLen, 24), 0xff),
			bit32.band(bit32.rshift(bitLen, 16), 0xff),
			bit32.band(bit32.rshift(bitLen, 8), 0xff),
			bit32.band(bitLen, 0xff)
		)

	local h0 = 0x6a09e667
	local h1 = 0xbb67ae85
	local h2 = 0x3c6ef372
	local h3 = 0xa54ff53a
	local h4 = 0x510e527f
	local h5 = 0x9b05688c
	local h6 = 0x1f83d9ab
	local h7 = 0x5be0cd19

	local w = table.create(64, 0)
	for offset = 1, #padded, 64 do
		for i = 1, 16 do
			local b1, b2, b3, b4 = string.byte(padded, offset + (i - 1) * 4, offset + i * 4 - 1)
			w[i] = bit32.bor(bit32.lshift(b1, 24), bit32.lshift(b2, 16), bit32.lshift(b3, 8), b4)
		end
		for i = 17, 64 do
			local s0 = bit32.bxor(bit32.rrotate(w[i - 15], 7), bit32.rrotate(w[i - 15], 18), bit32.rshift(w[i - 15], 3))
			local s1 = bit32.bxor(bit32.rrotate(w[i - 2], 17), bit32.rrotate(w[i - 2], 19), bit32.rshift(w[i - 2], 10))
			w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 2 ^ 32
		end

		local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
		for i = 1, 64 do
			local S1 = bit32.bxor(bit32.rrotate(e, 6), bit32.rrotate(e, 11), bit32.rrotate(e, 25))
			local ch = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
			local temp1 = (h + S1 + ch + K[i] + w[i]) % 2 ^ 32
			local S0 = bit32.bxor(bit32.rrotate(a, 2), bit32.rrotate(a, 13), bit32.rrotate(a, 22))
			local maj = bit32.bxor(bit32.band(a, b), bit32.band(a, c), bit32.band(b, c))
			local temp2 = (S0 + maj) % 2 ^ 32
			h = g
			g = f
			f = e
			e = (d + temp1) % 2 ^ 32
			d = c
			c = b
			b = a
			a = (temp1 + temp2) % 2 ^ 32
		end

		h0 = (h0 + a) % 2 ^ 32
		h1 = (h1 + b) % 2 ^ 32
		h2 = (h2 + c) % 2 ^ 32
		h3 = (h3 + d) % 2 ^ 32
		h4 = (h4 + e) % 2 ^ 32
		h5 = (h5 + f) % 2 ^ 32
		h6 = (h6 + g) % 2 ^ 32
		h7 = (h7 + h) % 2 ^ 32
	end

	return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

function PasswordHash.hashPassword(password: string, salt: string): string
	local digest = PasswordHash.sha256Hex(salt .. ":" .. password)
	for round = 1, 16 do
		digest = PasswordHash.sha256Hex(salt .. ":" .. tostring(round) .. ":" .. digest)
	end
	return digest
end

function PasswordHash.verify(password: string, salt: string, expectedHash: string): boolean
	local computed = PasswordHash.hashPassword(password, salt)
	if #computed ~= #expectedHash then
		return false
	end
	local diff = 0
	for i = 1, #computed do
		diff = bit32.bor(diff, bit32.bxor(string.byte(computed, i), string.byte(expectedHash, i)))
	end
	return diff == 0
end

return PasswordHash
