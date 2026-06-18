// This is the entry point
//
// To compile the static site, run `typst compile --features html,bundle --format bundle bundle.typ`

#import "config.typ": articles, blog-title, default-tagline
#import "template/mod.typ": index

#for article in articles [
  #document(article.basename + ".html", article.content) #article.label
]

#document("index.html", title: blog-title, index(
  articles: articles,
  blog-title: blog-title,
  tagline: default-tagline,
)) <index>
