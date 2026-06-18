#import "/template/mod.typ": post
#import "@preview/cmarker:0.1.8": render

#let config = toml("config.toml")

#let blog-title = config.title
#let default-tagline = config.at("default-tagline", default: "")

#let unsorted-articles = ()

#for article in config.at("articles") {
  if (article.at("draft", default: false)) {
    continue
  }

  let article_path = "posts/" + article.path
  let basename = article.path.replace(regex("\.(typ|md)$"), "")
  let article_label = label(basename)
  let tagline = article.at("tagline", default: default-tagline)

  let show-post = post.with(
    post-title: article.at("title", default: none),
    post-date: article.at("date", default: none),
    blog-title: blog-title,
    tagline: tagline,
  )

  let article_content = if (article_path.ends-with("md")) {
    let raw_text = read(article_path, encoding: "utf8")
    let article_rendered = render(
      raw_text,
      scope: (
        image: (source, alt: none, format: auto) => image("/static" + source, alt: alt, format: format),
      ),
    )

    [
      #show: show-post

      #article_rendered
    ]
  } else if (article_path.ends-with("typ")) {
    [
      #show: show-post

      #include article_path
    ]
  } else {
    assert(false, message: "Only markdown and Typst are supported")
  }

  unsorted-articles.push((
    basename: basename,
    title: article.title,
    date: article.date,
    label: article_label,
    content: article_content,
  ))
}

#let articles = unsorted-articles.sorted(key: article => article.date, by: (a, b) => a >= b)
