package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. package.path
local text = require("lib.text")
local first = nil
local previous = nil
local function emit(last)
  if first then io.write(string.format("0x%x, 0x%x\n", first, last)) end
end
for value = 0, 0x10ffff do
  local accepted = (text.safe_scalar(value) and not text.separator_scalar(value))
    or value == 0x200d -- Contextual GB11 sanitizer output.
  if accepted then
    if not first then first = value end
    previous = value
  elseif first then
    emit(previous)
    first, previous = nil, nil
  end
end
emit(previous)
