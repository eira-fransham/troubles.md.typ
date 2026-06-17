#import "config.typ": articles

#for article in articles [
  #html.elem("div", attrs: (class: "post-link"))[
    #link(article.label, article.title)
  ]
]
