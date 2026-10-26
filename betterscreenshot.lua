-- BetterScreenshot
-- Option+Shift+S -> select an area -> PNG saved to ~/Pictures/Screenshots + copied to clipboard,
-- then a native-looking notification toast with a thumbnail.
--
-- Load it from ~/.hammerspoon/init.lua with:   require("betterscreenshot")
-- After changing anything below, click the Hammerspoon menu bar icon -> Reload Config.

---------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------

local screenshotDir  = os.getenv("HOME") .. "/Pictures/Screenshots"  -- where screenshots are saved
local screenshotMods = { "alt", "shift" }    -- hotkey modifiers: "cmd", "alt" (Option), "ctrl", "shift"
local screenshotKey  = "s"                   -- hotkey key
local playSound      = false                 -- true = play the macOS camera shutter sound
local launchAtLogin  = true                  -- start Hammerspoon automatically when you log in

-- Toast timing (seconds)
local stayTime      = 2.5    -- how long the toast stays (paused while the mouse is over it)
local fadeInTime    = 0.3    -- fade + slide-in duration
local fadeOutTime   = 0.3
local slideDistance = 24     -- px it slides in from the right (0 when Reduce Motion is on)

-- Toast size and position
local toastWidth    = 344    -- native macOS banner width
local toastHeight   = 76
local marginTop     = 12     -- gap below the menu bar
local marginRight   = 14     -- gap from the screen's right edge
local innerPad      = 12     -- padding inside the banner
local toastRadius   = 18     -- banner corner radius
local thumbSize     = 52     -- thumbnail (right side, aspect fill)
local thumbRadius   = toastRadius - innerPad  -- concentric with the banner corner (= 6)
local appIconSize   = 16     -- Screenshot app icon on the header line
local appName       = "Screenshot"

-- Hover behavior
local hoverFadeTime  = 0.15  -- how fast the X and "Open in Finder" fade in/out
local hoverPoll      = 0.05  -- how often the mouse position is checked
local hoverExitDelay = 0.15  -- mouse must be outside this long before controls hide
local hoverMargin    = 4     -- px of slack around the banner that still counts as hovering

-- Fonts (SF Pro via the system font)
local appNameFont  = { name = ".AppleSystemUIFont",       size = 11 }
local titleFont    = { name = ".AppleSystemUIFontDemi",   size = 13 }  -- Demi = semibold
local subtitleFont = { name = ".AppleSystemUIFont",       size = 12 }
local buttonFontName, buttonFontSize = ".AppleSystemUIFontMedium", 11

-- "Open in Finder" pill (fades in on hover)
local buttonText    = "Open in Finder"
local buttonWidth   = 92
local buttonHeight  = 22

-- Close (X) button overlapping the top-left corner (fades in on hover)
local closeSize     = 18     -- visible circle diameter
local closeInset    = 4      -- circle center sits this far inside the banner's corner
local closeHitSize  = 26     -- clickable area is larger than the circle

-- Colors for light and dark mode, modeled on macOS semantic colors
local themes = {
  dark = {
    bg            = { red = 30/255, green = 30/255, blue = 30/255, alpha = 0.98 },
    border        = { white = 1, alpha = 0.10 },
    label         = { white = 1, alpha = 0.85 },
    secondary     = { white = 1, alpha = 0.55 },
    thumbBg       = { white = 1, alpha = 0.06 },
    thumbBorder   = { white = 1, alpha = 0.10 },
    pill          = { white = 1, alpha = 0.10 },
    pillHover     = { white = 1, alpha = 0.18 },
    shadowWide    = 0.50,   -- shadow opacities
    shadowContact = 0.35,
  },
  light = {
    bg            = { red = 250/255, green = 250/255, blue = 250/255, alpha = 0.98 },
    border        = { white = 0, alpha = 0.10 },
    label         = { white = 0, alpha = 0.85 },
    secondary     = { white = 0, alpha = 0.50 },
    thumbBg       = { white = 0, alpha = 0.04 },
    thumbBorder   = { white = 0, alpha = 0.08 },
    pill          = { white = 0, alpha = 0.05 },
    pillHover     = { white = 0, alpha = 0.10 },
    shadowWide    = 0.18,
    shadowContact = 0.10,
  },
}

---------------------------------------------------------------------
-- Toast (built with hs.canvas)
---------------------------------------------------------------------

if launchAtLogin then hs.autoLaunch(true) end

-- Transparent room around the banner for the shadow and the close button overhang.
-- Right = marginRight so the window never hangs off the screen edge.
-- Top stays small so the invisible area doesn't cover the menu bar.
local padTop, padLeft, padRight, padBottom = 12, 24, marginRight, 36

-- The toast currently on screen: { canvas = ..., timers = { name = hs.timer } }
local toast = nil

-- Stop and remove every timer a toast owns (slide, poll, hover fade, dismiss)
local function stopToastTimers(t)
  for _, timer in pairs(t.timers) do timer:stop() end
  t.timers = {}
end

-- Remove the current toast (replaced, clicked, or timed out)
local function dismissToast(fadeTime)
  if not toast then return end
  local t = toast
  toast = nil
  stopToastTimers(t)
  -- delete() frees the canvas; it errors on a nil fade time, so only pass one if given
  if fadeTime then t.canvas:delete(fadeTime) else t.canvas:delete() end
end

-- (Re)start the countdown that fades the toast out
local function startDismissTimer(t, delay)
  if t.timers.dismiss then t.timers.dismiss:stop() end
  t.timers.dismiss = hs.timer.doAfter(delay, function()
    if toast == t then dismissToast(fadeOutTime) end
  end)
end

-- Read a macOS accessibility preference (Reduce Motion / Reduce Transparency)
local function accessibilityPref(key)
  local out = hs.execute("defaults read com.apple.universalaccess " .. key .. " 2>/dev/null")
  return out ~= nil and out:match("1") ~= nil
end

-- Copy of a color with its alpha multiplied by `a`
local function fade(color, a)
  local c = {}
  for k, v in pairs(color) do c[k] = v end
  c.alpha = (color.alpha or 1) * a
  return c
end

-- Frame that makes an image cover a square (aspect fill), centered; a clip trims the overflow
local function aspectFillFrame(img, rect)
  local size = img and img:size()
  if not size or size.w == 0 or size.h == 0 then return rect end
  local scale = math.max(rect.w / size.w, rect.h / size.h)
  local w, h = size.w * scale, size.h * scale
  return { x = rect.x + (rect.w - w) / 2, y = rect.y + (rect.h - h) / 2, w = w, h = h }
end

local function inRect(px, py, r)
  return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h
end

local function showToast(path)
  dismissToast()  -- replace any toast that's still showing instead of stacking

  local theme = (hs.host.interfaceStyle() == "Dark") and themes.dark or themes.light
  local reduceMotion = accessibilityPref("reduceMotion")
  local bgColor = accessibilityPref("reduceTransparency") and fade(theme.bg, 1 / theme.bg.alpha) or theme.bg
  local slide = reduceMotion and 0 or slideDistance

  -- Top-right of the screen the mouse is on. frame() starts just below the menu bar.
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local sf = screen:frame()
  local canvasW = padLeft + toastWidth + padRight
  local finalX = sf.x + sf.w - canvasW
  local finalY = sf.y + marginTop - padTop

  local canvas = hs.canvas.new({
    x = finalX + slide, y = finalY,  -- starts a bit to the right, slides in
    w = canvasW, h = padTop + toastHeight + padBottom,
  })
  local t = { canvas = canvas, timers = {} }

  -- Float above normal windows, show on every Space, stay out of Mission Control
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior({ "canJoinAllSpaces", "transient", "ignoresCycle" })

  -- Layout (canvas coordinates, 4pt grid)
  local box    = { x = padLeft, y = padTop, w = toastWidth, h = toastHeight }
  local left   = box.x + innerPad
  local thumb  = { x = box.x + box.w - innerPad - thumbSize, y = box.y + (box.h - thumbSize) / 2, w = thumbSize, h = thumbSize }
  local btn    = { x = thumb.x - 8 - buttonWidth, y = box.y + (box.h - buttonHeight) / 2, w = buttonWidth, h = buttonHeight }
  local btnHit = { x = btn.x - 4, y = btn.y - 4, w = btn.w + 8, h = btn.h + 8 }
  local textW  = thumb.x - 8 - left   -- text may run under the pill; the pill only shows on hover
  local closeC = { x = box.x + closeInset, y = box.y + closeInset }
  local closeR = closeSize / 2
  -- Hover area = banner + the close button overhang + a little slack
  local hoverArea = {
    x = closeC.x - closeR - hoverMargin, y = closeC.y - closeR - hoverMargin,
    w = (box.x + box.w + hoverMargin) - (closeC.x - closeR - hoverMargin),
    h = (box.y + box.h + hoverMargin) - (closeC.y - closeR - hoverMargin),
  }

  -- Hover state (driven by the mouse poll below)
  local hovering, lastInside = false, 0
  local hoverAlpha, hoverTarget = 0, 0
  local pillHot = false

  -- Every element is created once and never removed. Hover-only elements register a
  -- function that returns their attribute value for a given opacity (0..1).
  local elements, hoverAttrs = {}, {}
  local function add(el) table.insert(elements, el); return #elements end
  local function addHover(el, attr, valueFor)
    el[attr] = valueFor(0)  -- start invisible
    table.insert(hoverAttrs, { index = add(el), attr = attr, valueFor = valueFor })
  end
  local function applyHover()
    for _, h in ipairs(hoverAttrs) do
      canvas:elementAttribute(h.index, h.attr, h.valueFor(hoverAlpha))
    end
  end

  -- Banner: wide soft shadow + tight contact shadow (like macOS window shadows)
  local bannerShape = { xRadius = toastRadius, yRadius = toastRadius }
  add({
    type = "rectangle", action = "fill", frame = box, roundedRectRadii = bannerShape, fillColor = bgColor,
    withShadow = true, shadow = { blurRadius = 28, color = { alpha = theme.shadowWide }, offset = { h = -10, w = 0 } },
  })
  add({
    type = "rectangle", action = "fill", frame = box, roundedRectRadii = bannerShape, fillColor = bgColor,
    withShadow = true, shadow = { blurRadius = 3, color = { alpha = theme.shadowContact }, offset = { h = -1, w = 0 } },
  })
  -- Hairline 0.5px border
  add({
    type = "rectangle", action = "stroke",
    frame = { x = box.x + 0.25, y = box.y + 0.25, w = box.w - 0.5, h = box.h - 0.5 },
    roundedRectRadii = bannerShape, strokeColor = theme.border, strokeWidth = 0.5,
  })

  -- Header line: Screenshot app icon + "Screenshot"
  local appIcon = hs.image.imageFromAppBundle("com.apple.screenshot.launcher")
  if appIcon then
    add({
      type = "image", image = appIcon, imageScaling = "scaleProportionally",
      frame = { x = left, y = box.y + 12, w = appIconSize, h = appIconSize },
    })
  end
  add({
    type = "text",
    frame = { x = left + appIconSize + 6, y = box.y + 13, w = textW, h = 14 },
    text = hs.styledtext.new(appName, { font = appNameFont, color = theme.secondary }),
  })

  -- Title + subtitle
  add({
    type = "text",
    frame = { x = left, y = box.y + 31, w = textW, h = 17 },
    text = hs.styledtext.new("Screenshot saved", { font = titleFont, color = theme.label }),
  })
  add({
    type = "text",
    frame = { x = left, y = box.y + 47, w = textW, h = 16 },
    text = hs.styledtext.new("Copied to clipboard", { font = subtitleFont, color = theme.secondary }),
  })

  -- Thumbnail: rounded clip, faint backing, image (aspect fill), unclip, hairline edge
  local img = hs.image.imageFromPath(path)
  local thumbShape = { xRadius = thumbRadius, yRadius = thumbRadius }
  add({ type = "rectangle", action = "clip", frame = thumb, roundedRectRadii = thumbShape })
  add({ type = "rectangle", action = "fill", frame = thumb, fillColor = theme.thumbBg })
  if img then
    add({ type = "image", image = img, imageScaling = "scaleToFit", frame = aspectFillFrame(img, thumb) })
  end
  add({ type = "resetClip" })
  add({
    type = "rectangle", action = "stroke",
    frame = { x = thumb.x + 0.25, y = thumb.y + 0.25, w = thumb.w - 0.5, h = thumb.h - 0.5 },
    roundedRectRadii = thumbShape, strokeColor = theme.thumbBorder, strokeWidth = 0.5,
  })

  -- "Open in Finder" pill (fades in on hover, brightens when the pill itself is hovered)
  addHover({
    type = "rectangle", action = "fill", frame = btn,
    roundedRectRadii = { xRadius = buttonHeight / 2, yRadius = buttonHeight / 2 },
  }, "fillColor", function(a) return fade(pillHot and theme.pillHover or theme.pill, a) end)
  addHover({
    type = "text", text = buttonText,
    textFont = buttonFontName, textSize = buttonFontSize, textAlignment = "center",
    frame = { x = btn.x, y = btn.y + (buttonHeight - 14) / 2, w = btn.w, h = 16 },
  }, "textColor", function(a) return fade(theme.label, a) end)

  -- Close (X) button: circle with banner background, hairline, soft shadow, grey glyph
  addHover({
    type = "circle", action = "fill", center = closeC, radius = closeR,
    withShadow = true,
  }, "fillColor", function(a) return fade(bgColor, a) end)
  table.insert(hoverAttrs, { index = #elements, attr = "shadow", valueFor = function(a)
    return { blurRadius = 4, color = { alpha = 0.25 * a }, offset = { h = -1, w = 0 } }
  end })
  addHover({
    type = "circle", action = "stroke", center = closeC, radius = closeR - 0.25, strokeWidth = 0.5,
  }, "strokeColor", function(a) return fade(theme.border, a) end)
  local arm = 3.25  -- half-length of each X stroke
  for _, s in ipairs({ { -1, -1, 1, 1 }, { 1, -1, -1, 1 } }) do
    addHover({
      type = "segments", action = "stroke", closed = false,
      coordinates = { { x = closeC.x + s[1] * arm, y = closeC.y + s[2] * arm },
                      { x = closeC.x + s[3] * arm, y = closeC.y + s[4] * arm } },
      strokeWidth = 1.5, strokeCapStyle = "round",
    }, "strokeColor", function(a) return fade(theme.secondary, a) end)
  end

  canvas:appendElements(elements)
  applyHover()

  -- Animate the hover controls' opacity toward hoverTarget
  local function animateHover(target)
    hoverTarget = target
    if t.timers.hoverFade then return end  -- already animating; it will pick up the new target
    t.timers.hoverFade = hs.timer.doEvery(1 / 60, function()
      local step = (1 / 60) / hoverFadeTime
      if hoverAlpha < hoverTarget then
        hoverAlpha = math.min(hoverAlpha + step, hoverTarget)
      else
        hoverAlpha = math.max(hoverAlpha - step, hoverTarget)
      end
      applyHover()
      if hoverAlpha == hoverTarget then t.timers.hoverFade:stop(); t.timers.hoverFade = nil end
    end)
  end

  -- Hover tracking: poll the mouse position instead of relying on enter/exit events
  t.timers.poll = hs.timer.doEvery(hoverPoll, function()
    if toast ~= t then return end
    local f = canvas:frame()
    local m = hs.mouse.absolutePosition()
    local mx, my = m.x - f.x, m.y - f.y
    local now = hs.timer.secondsSinceEpoch()

    if inRect(mx, my, hoverArea) then
      lastInside = now
      if not hovering then
        hovering = true
        animateHover(1)
        if t.timers.dismiss then t.timers.dismiss:stop(); t.timers.dismiss = nil end  -- pause
      end
    elseif hovering and now - lastInside >= hoverExitDelay then
      hovering = false
      animateHover(0)
      startDismissTimer(t, stayTime)  -- resume with a fresh countdown
    end

    local hot = hovering and inRect(mx, my, btnHit)
    if hot ~= pillHot then pillHot = hot; applyHover() end
  end)

  -- Clicks: X = dismiss, pill = reveal in Finder + dismiss, anywhere else = dismiss
  canvas:canvasMouseEvents(true, false, false, false)
  canvas:mouseCallback(function(c, message, id, mx, my)
    if message ~= "mouseDown" or toast ~= t then return end
    local controlsShown = hovering or hoverAlpha > 0.5
    if controlsShown and inRect(mx, my, btnHit) then
      hs.task.new("/usr/bin/open", nil, { "-R", path }):start()  -- reveal + select in Finder
    end
    dismissToast(fadeOutTime)
  end)

  toast = t
  canvas:show(fadeInTime)

  -- Slide in from the right while fading in (ease-out cubic)
  if slide > 0 then
    local startTime = hs.timer.secondsSinceEpoch()
    t.timers.slide = hs.timer.doEvery(1 / 60, function()
      local p = math.min((hs.timer.secondsSinceEpoch() - startTime) / fadeInTime, 1)
      local eased = 1 - (1 - p) ^ 3
      canvas:topLeft({ x = finalX + slide * (1 - eased), y = finalY })
      if p >= 1 then t.timers.slide:stop(); t.timers.slide = nil end
    end)
  end

  -- After fade-in + stay time, fade out and delete (paused while hovering)
  startDismissTimer(t, fadeInTime + stayTime)
  return canvas
end

---------------------------------------------------------------------
-- Screenshot
---------------------------------------------------------------------

-- Keep a reference to the running task so Lua doesn't garbage-collect it mid-capture
local screenshotTask = nil

local function takeScreenshot()
  -- Don't start a second capture while one is already open
  if screenshotTask and screenshotTask:isRunning() then return end

  -- Make sure the folder exists (no-op if it already does)
  hs.fs.mkdir(screenshotDir)

  -- Timestamped filename, e.g. Screenshot_2026-10-12_02-56-01.png
  local path = screenshotDir .. "/Screenshot_" .. os.date("%Y-%m-%d_%H-%M-%S") .. ".png"

  -- -i = interactive area selection (Space toggles window mode, Esc cancels)
  -- -x = no shutter sound
  local args = { "-i", path }
  if not playSound then args = { "-i", "-x", path } end

  screenshotTask = hs.task.new("/usr/sbin/screencapture", function(exitCode, stdOut, stdErr)
    -- If you pressed Escape, screencapture writes no file, so we just do nothing
    if not hs.fs.attributes(path) then return end

    local img = hs.image.imageFromPath(path)
    if img then
      hs.pasteboard.writeObjects(img)  -- copy to clipboard
      showToast(path)
    else
      hs.alert.show("Screenshot saved (clipboard copy failed)", 1.5)
    end
  end, args)

  screenshotTask:start()
end

hs.hotkey.bind(screenshotMods, screenshotKey, takeScreenshot)

return { takeScreenshot = takeScreenshot, showToast = showToast }
