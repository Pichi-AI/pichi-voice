-- Resolve repository links at publication time, keeping the Markdown usable on GitHub.
function Link(link)
  local pages = {
    ["user-guide.md"] = "/voice/docs/",
    ["user-guide.ru.md"] = "/ru/voice/docs/",
    ["../../SUPPORT.md"] = "https://github.com/Pichi-AI/pichi-voice/blob/main/SUPPORT.md",
  }
  if link.target == "user-guide.md" then link.attributes.lang = "en" end
  if link.target == "user-guide.ru.md" then link.attributes.lang = "ru" end
  if pages[link.target] then
    link.target = pages[link.target]
  elseif link.target:match("^https://pichi%.ai/") then
    link.target = link.target:gsub("^https://pichi%.ai", "")
  elseif not link.target:match("^%a[%w+.-]*:") and not link.target:match("^[#/]") then
    local path = pandoc.path.normalize(pandoc.path.join({"docs", "product", link.target}))
    link.target = "https://github.com/Pichi-AI/pichi-voice/blob/main/" .. path
  end
  return link
end

-- The opening title and link row are shared with the GitHub version.
function Pandoc(doc)
  local title, links = doc.blocks[1], doc.blocks[2]
  assert(title and title.t == "Header" and title.level == 1, "Guide must start with its title")
  assert(links and links.t == "Para" and links.content[1].t == "Link", "Expected guide navigation")
  doc.meta.title = title.content
  doc.meta["guide-links"] = links.content
  doc.blocks:remove(1)
  doc.blocks:remove(1)
  return doc
end
