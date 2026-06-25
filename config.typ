#import "/template/mod.typ": post
#import "@preview/cmarker:0.1.8": render

#let config = toml("config.toml")

#let blog-title = config.title
#let default-tagline = config.at("default-tagline", default: "")
#let site-url = if config.url.ends-with("/") { config.url } else { config.url + "/" }
#let feed-url = site-url + "feed.xml"

#let syntax-theme = (
  dark: config.at("syntax", default: (:)).at("dark-theme", default: none),
  light: config.at("syntax", default: (:)).at("light-theme", default: none),
)

#let _xml-escape-text(value) = {
  str(value)
    .replace("&", "&amp;")
    .replace("<", "&lt;")
    .replace(">", "&gt;")
}

#let _xml-escape-attr(value) = {
  _xml-escape-text(value)
    .replace("\"", "&quot;")
    .replace("'", "&apos;")
}

#let _atom-date(value) = value.display("[year]-[month padding:zero]-[day padding:zero]T00:00:00Z")
#let unsorted-articles = ()

#for article in config.at("articles") {
  if (article.at("draft", default: false)) {
    continue
  }

  let article_path = "posts/" + article.path
  let basename = article.path.replace(regex("\.(typ|md)$"), "")
  let article_label = label(basename)
  let tagline = article.at("tagline", default: default-tagline)
  let article-url = site-url + basename + "/"

  let show-post = post.with(
    post-title: article.at("title", default: none),
    post-date: article.at("date", default: none),
    syntax-theme: syntax-theme,
    blog-title: blog-title,
    tagline: tagline,
    feed-url: feed-url,
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
    url: article-url,
    content: article_content,
  ))
}

#let articles = unsorted-articles.sorted(key: article => article.date, by: (a, b) => a >= b)
#let atom-feed = {
  let updated = if articles.len() > 0 {
    _atom-date(articles.at(0).date)
  } else {
    "1970-01-01T00:00:00Z"
  }
  let entries = articles.map(article =>
    (
      "  <entry>",
      "    <title>" + _xml-escape-text(article.title) + "</title>",
      "    <link href=\"" + _xml-escape-attr(article.url) + "\" />",
      "    <id>" + _xml-escape-text(article.url) + "</id>",
      "    <updated>" + _atom-date(article.date) + "</updated>",
      "  </entry>",
    ).join("\n")
  ).join("\n")

  (
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
    "<feed xmlns=\"http://www.w3.org/2005/Atom\">",
    "  <title>" + _xml-escape-text(blog-title) + "</title>",
    "  <link href=\"" + _xml-escape-attr(site-url) + "\" />",
    "  <link href=\"" + _xml-escape-attr(feed-url) + "\" rel=\"self\" />",
    "  <id>" + _xml-escape-text(feed-url) + "</id>",
    "  <updated>" + updated + "</updated>",
    entries,
    "</feed>",
  ).join("\n")
}
