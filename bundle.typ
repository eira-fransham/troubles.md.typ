// This is the entry point
//
// To compile the static site, run `typst compile --features html,bundle --format bundle bundle.typ`

#import "config.typ": articles, blog_title

#for article in articles [
  #document(article.basename + ".html", title: article.title + " - " + blog_title, article.content) #article.label
]

#document("index.html", title: blog_title)[
  #include "index.typ"
] <index>
