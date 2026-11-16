-- Hide the raw SP7 libcamera nodes (sp7.rear.*, sp7.front.*) from apps.
-- Apps must use the v4l2loopback nodes managed by sp7-camera-controller;
-- opening a raw node directly races the controller (EBUSY on the shared IPU)
-- and can wedge the front CSI link until reboot.
log = Log.open_topic ("s-sp7-hide")

ALLOWED_BINARIES = {
  ["gst-launch-1.0"] = true,   -- sp7-camera-controller pipelines
  ["wireplumber"] = true,
  ["pipewire"] = true,
}

local function is_raw (node)
  local name = node.properties["node.name"] or ""
  return node.properties["device.api"] == "libcamera" and name:match ("^sp7%.") ~= nil
end

local function is_allowed (client)
  local bin = client.properties["application.process.binary"] or ""
  return ALLOWED_BINARIES[bin] == true
end

clients_om = ObjectManager { Interest { type = "client" } }
nodes_om = ObjectManager { Interest { type = "node" } }

local function apply_client (client)
  if is_allowed (client) then return end
  local perms = {}
  local any = false
  for node in nodes_om:iterate () do
    if is_raw (node) then
      perms[node["bound-id"]] = "-"
      any = true
    end
  end
  if any then client:update_permissions (perms) end
end

local function apply_all ()
  for client in clients_om:iterate () do apply_client (client) end
end

-- Deferred so we run after access-default / access-portal grants.
local pending = false
local function schedule ()
  if pending then return end
  pending = true
  Core.idle_add (function () pending = false; apply_all (); return false end)
end

clients_om:connect ("object-added", function () schedule () end)
nodes_om:connect ("object-added", function () schedule () end)

local pps = Plugin.find ("portal-permissionstore")
if pps then
  pps:connect ("changed", function () schedule () end)
end

clients_om:activate ()
nodes_om:activate ()
