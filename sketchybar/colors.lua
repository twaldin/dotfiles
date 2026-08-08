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
  warning = 0xffffcc80,
  critical = 0xffffc1c1,
  transparent = 0x00000000,
}

-- Compatibility aliases keep domain modules semantic while the visual system
-- has one source of truth.
M.background = M.bar
M.popup = M.surface
M.normal = M.primary
M.active = M.primary
M.soft = M.muted
M.dim = M.muted
M.hover = M.right_hover
return M
