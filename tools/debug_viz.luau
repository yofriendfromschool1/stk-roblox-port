-- SPDX-License-Identifier: GPL-3.0-or-later
-- Edit-mode debug visualizer for Workspace.Tracks.sandtrack logic volumes.

local track = workspace.Tracks.sandtrack

local quads = track.Driveline:GetChildren()
table.sort(quads, function(a, b)
	return a.Name < b.Name
end)

local minV = Vector3.new(math.huge, math.huge, math.huge)
local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)

for i, q in ipairs(quads) do
	if q:IsA("BasePart") then
		q.Transparency = 0.5
		q.Material = Enum.Material.Neon
		q.Color = Color3.fromHSV((i - 1) / #quads * 0.85, 1, 1)
		minV = minV:Min(q.Position)
		maxV = maxV:Max(q.Position)
	end
end

local checks = track.Checkpoints:GetChildren()
for _, c in ipairs(checks) do
	if c:IsA("BasePart") then
		c.Transparency = 0.35
		c.Material = Enum.Material.Neon
		c.Color = Color3.fromRGB(255, 40, 40)
	end
end

track.MainTrack.Transparency = 1
for _, d in ipairs(track.SceneObjects:GetDescendants()) do
	if d:IsA("BasePart") then
		d.Transparency = 1
	end
end

local items = track.Items:GetChildren()
local center = (minV + maxV) * 0.5
local span = maxV - minV

return string.format(
	"quads=%d checks=%d items=%d center=(%.1f, %.1f, %.1f) span=(%.1f, %.1f, %.1f)",
	#quads,
	#checks,
	#items,
	center.X,
	center.Y,
	center.Z,
	span.X,
	span.Y,
	span.Z
)
