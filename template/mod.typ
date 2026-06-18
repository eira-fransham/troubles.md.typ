#import "@preview/zebraw:0.6.3": *
#import "local-footnotes.typ": local-footnote, local-footnotes-show

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

#let date-format = "[day] [month repr:long], [year]";
#let date-format-short = "[day].[month].[year repr:last_two]";

#let date(datetime) = {
  html.elem("aside", attrs: (class: "date-full"), datetime.display(date-format))
  html.elem("aside", attrs: (class: "date-short"), datetime.display(date-format-short))
}

#let post(
  post-title: none,
  post-date: none,
  blog-title: none,
  tagline: none,
  body,
) = context {
  set quote(block: true)

  let post-title = if post-title != none { post-title } else { body.at("title", default: none) }
  let post-date = if post-date != none { post-date } else { body.at("date", default: none) }

  html.html[
    #html.head[
      #html.elem("meta", attrs: (charset: "utf-8"))
      // TODO: This puts it inline, we should make it a separate asset
      #html.elem("style", read("/template/static/css/style.css"))
    ]
    #html.body[
      #div("main")[
        #header(
          blog-title: blog-title,
          tagline: tagline,
        )
        #div("post")[
          #div("title")[
            #title(post-title)
            #date(post-date)
          ]

          #div("content", context [
            #let article-slug = lower(post-title).replace(regex("[^a-z]"), "")
            #let local-footnotes-state = state("local-footnotes-" + article-slug, (
              notes: (),
              numbering-format: "1",
              article: article-slug,
            ))

            #show footnote: note => local-footnote(note.body, state: local-footnotes-state)

            #body

            #local-footnotes-show(state: local-footnotes-state, here())
          ])
        ]
      ]
    ]
  ]
}

#let index(articles: (), blog-title: none, tagline: none) = [
  #html.html[
    #html.head[
      #html.elem("meta", attrs: (charset: "utf-8"))
      // TODO: This puts it inline, we should make it a separate asset
      #html.elem("style", read("/template/static/css/style.css"))
    ]

    #html.body[
      #div("main")[
        #header(
          blog-title: blog-title,
          tagline: tagline,
        )
        #div("content")[
          #title[Posts]

          #for article in articles [
            #html.elem("div", attrs: (class: "post-link"))[
              #link(article.label, article.title)
              #date(article.date)
            ]
          ]
        ]
      ]
    ]
  ]
]
