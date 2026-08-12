local M = {
  bar = 0x00000000,
  surface = 0xff181b1f,
  surface2 = 0xff23272c,
  border = 0xff343a40,
  right_event = 0xff242932,
  right_date = 0xff303744,
  right_system = 0xff3b4352,
  right_hover = 0xff4c566a,
  primary = 0xffe7eaed,
  muted = 0xffc5cbd3,
  accent = 0xffd8dee9,
  accent_fill = 0x224f565e,
  blue = 0xff4f9dff,
  blue_fill = 0x184f9dff,
  cyan = 0xff55d6d9,
  cyan_fill = 0x1855d6d9,
  purple = 0xff7b6cff,
  purple_fill = 0x187b6cff,
  magenta = 0xffc678dd,
  magenta_fill = 0x18c678dd,
  orange = 0xffffa657,
  orange_fill = 0x18ffa657,
  slate = 0xff9aa8ba,
  green = 0xff72d572,
  green_fill = 0x1872d572,
  red = 0xffff5d62,
  red_fill = 0x18ff5d62,
  warning = 0xffffcc80,
  critical = 0xffffc1c1,
  transparent = 0x00000000,
}

-- Compatibility aliases keep domain modules semantic while the visual system
-- has one source of truth.
M.domain = {
  cpu = M.blue, gpu = M.magenta, ram = M.green, net = M.cyan,
  ssd = M.purple, tmp = M.slate, wifi = M.cyan, bluetooth = M.blue,
  sound = M.purple, mic = M.magenta, display = M.orange, battery = M.green,
}
M.severity = { normal = M.primary, elevated = M.warning, critical = M.red }
M.state = { normal = M.primary, selected = M.accent, busy = M.warning, missing = M.muted, unresolved = M.slate, actionable = M.orange, recording = M.magenta }

M.background = M.bar
M.popup = M.surface
M.normal = M.primary
M.active = M.primary
M.soft = M.muted
M.dim = M.muted
M.hover = M.right_hover
return M
