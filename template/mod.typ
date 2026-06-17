#import "@preview/zebraw:0.6.3": *

#let div(class, body) = html.elem("div", attrs: (class: class), body)
#let span(class, body) = html.elem("span", attrs: (class: class), body)

#let header(blog-title: "My Blog", tagline: none) = [
  #html.elem("header")[
    #html.elem("span")[
      #span("blog-name")[
        #link(<index>)[#blog-title]
      ]
      #if tagline != none [
        #span("separator")[-]
        #span("tagline", tagline)
      ]
    ]
  ]
  #html.elem("span")
]

#let post(
  title: "Unknown post",
  date: datetime.today(),
  blog-title: none,
  tagline: none,
  body,
) = [
  #show footnote: none

  #context {
    counter("zebraw-html-styles").update(1)
  }

  #html.html[
    #html.head[
      #html.elem("meta", attrs: (charset: "utf-8"))
      // The zebraw CSS file isn't properly emitted by `zebraw-init` when compiling as a bundle
      // TODO: This puts it inline, we should make it a separate asset
      #html.elem("style", read("/template/static/css/style.css"))
      // #html.elem("style", [
      //   #read("/template/static/css/zebraw-config.css")
      //   #read("/template/static/css/zebraw.css")
      // ])
      // #html.elem("script", attrs: (async: ""), read("/template/static/script/clipboard-copy.js"))
    ]

    #html.body[
      #header(
        blog-title: blog-title,
        tagline: tagline,
      )

      #div("post")[
        #div("title")[
          = #title
          ==== #date.display(
            "[day] [month repr:long], [year]",
          )
        ]

        #div("content", body)
      ]
    ]
  ]

]
