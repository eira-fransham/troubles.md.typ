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
