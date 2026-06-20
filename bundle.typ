// This is the entry point
//
// To compile the static site, run `typst compile --features html,bundle --format bundle bundle.typ`

#import "config.typ": articles, blog-title, default-tagline
#import "template/mod.typ": favicon, index, main-image

#for article in articles [
  #document(article.basename + "/index.html", article.content) #article.label
]

#document("index.html", title: blog-title, index(
  articles: articles,
  blog-title: blog-title,
  tagline: default-tagline,
)) <index>

#asset(
  "favicon.ico",
  favicon,
)

#asset(
  "css/style.css",
  read("template/static/css/style.css"),
)

#asset(
  "css/drafting-mono.css",
  read("template/static/css/drafting-mono.css"),
)

#asset(
  "github-logo.svg",
  read("template/static/images/github-logo.svg"),
)

#asset(
  "floppies.png",
  main-image,
)

#asset(
  "CNAME",
  read("static/CNAME"),
)

#asset("/fonts/DraftingMono-ExtraLight.woff2", read(
  "template/static/fonts/DraftingMono-ExtraLight.woff2",
  encoding: none,
))
#asset("/fonts/DraftingMono-Light.woff2", read("template/static/fonts/DraftingMono-Light.woff2", encoding: none))
#asset("/fonts/DraftingMono-Medium.woff2", read("template/static/fonts/DraftingMono-Medium.woff2", encoding: none))
#asset("/fonts/DraftingMono-Regular.woff2", read("template/static/fonts/DraftingMono-Regular.woff2", encoding: none))
#asset("/fonts/DraftingMono-SemiBold.woff2", read("template/static/fonts/DraftingMono-SemiBold.woff2", encoding: none))
#asset("/fonts/DraftingMono-Bold.woff2", read("template/static/fonts/DraftingMono-Bold.woff2", encoding: none))
#asset("/fonts/DraftingMono-ExtraLightItalic.woff2", read(
  "template/static/fonts/DraftingMono-ExtraLightItalic.woff2",
  encoding: none,
))
#asset("/fonts/DraftingMono-LightItalic.woff2", read(
  "template/static/fonts/DraftingMono-LightItalic.woff2",
  encoding: none,
))
#asset("/fonts/DraftingMono-MediumItalic.woff2", read(
  "template/static/fonts/DraftingMono-MediumItalic.woff2",
  encoding: none,
))
#asset("/fonts/DraftingMono-Italic.woff2", read("template/static/fonts/DraftingMono-Italic.woff2", encoding: none))
#asset("/fonts/DraftingMono-SemiBoldItalic.woff2", read(
  "template/static/fonts/DraftingMono-SemiBoldItalic.woff2",
  encoding: none,
))
#asset("/fonts/DraftingMono-BoldItalic.woff2", read(
  "template/static/fonts/DraftingMono-BoldItalic.woff2",
  encoding: none,
))
