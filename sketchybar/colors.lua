local M = {
  bar = 0x00000000,
  surface = 0xff181b1f,
  surface2 = 0xff23272c,
  border = 0xff343a40,
  primary = 0xffe7eaed,
  muted = 0xff858b92,
  accent = 0xffb8c0c8,
  accent_fill = 0x224f565e,
  warning = 0xffe3a55b,
  critical = 0xffff6b6b,
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
M.hover = M.surface2
return M
