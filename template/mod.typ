#let post(
  title: "Unknown post",
  date: datetime.today(),
  body,
) = [
  // The zebraw CSS file isn't properly emitted by `zebraw-init` when compiling as a bundle
  #html.elem("style", read("/template/static/css/zebraw.css"))

  = #title
  ==== #date.display(
    "[day] [month repr:long], [year]",
  )

  #body
]
