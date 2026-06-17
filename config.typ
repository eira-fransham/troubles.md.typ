#import "/template/mod.typ": post
#import "@preview/cmarker:0.1.8": render

#let config = toml("config.toml")

#let blog_title = config.title

#let articles = ()

#for article in config.at("articles") {
  if (article.at("draft", default: false)) {
    continue
  }

  let article_path = "posts/" + article.path
  let basename = article.path.replace(regex("\.(typ|md)$"), "")
  let article_label = label(basename)
  let tagline = article.at("tagline", default: config.at("default-tagline"))

  let show_post = post.with(
    title: article.title,
    date: article.date,
    blog-title: blog_title,
    tagline: tagline,
  )

  assert(article.at("title", default: none) != none, message: repr(article))

  if (article_path.ends-with("md")) {
    let raw_text = read(article_path, encoding: "utf8")
    let article_rendered = render(
      raw_text,
      scope: (
        image: (source, alt: none, format: auto) => image("/static" + source, alt: alt, format: format),
      ),
    )
    let article_content = [
      #show: show_post

      #article_rendered
    ]

    articles.push((
      basename: basename,
      title: article.title,
      label: article_label,
      content: article_content,
    ))
  } else if (article_path.ends-with("typ")) {
    let article_content = [
      #show: show_post

      #include article_path
    ]

    articles.push((
      basename: basename,
      title: article.title,
      label: article_label,
      content: article_content,
    ))
  } else {
    assert(false, message: "Only markdown and Typst are supported")
  }
}
