/// (internal) unique ID per group of local footnotes
#let _local-footnotes-counter = counter("local-footnotes")

/// (internal) Creates labels for linking from ref to note and vice versa
#let _local-footnotes-labels(article, footnotes-group-id, index) = {
  (
    ref: label("_local-footnotes-ref-" + str(article) + "-" + str(footnotes-group-id) + "-" + str(index)),
    note: label("_local-footnotes-note-" + str(article) + "-" + str(footnotes-group-id) + "-" + str(index)),
  )
}
#let _local-footnotes-format(notes) = {
  set text(size: 0.9em)
  parbreak()
  // Indent notes, similar to what `footnote` does
  pad(left: 1em, notes)
  parbreak()
  v(1em)
}

/// Shows the local footnotes which have been added so far, and resets the list of footnotes.
/// The `format` parameter can be used to overwrite the default formatting of the footnotes.
#let local-footnotes-show(location, format: _local-footnotes-format, state: none) = context {
  let local-footnotes-state = state.at(location)
  let footnotes = local-footnotes-state.notes
  if footnotes.len() == 0 {
    return
  }
  local-footnotes-state.notes = ()
  state.update(local-footnotes-state)
  _local-footnotes-counter.step()
  let footnotes-group-id = _local-footnotes-counter.at(location).at(0)
  let numbering-format = local-footnotes-state.numbering-format
  let article = local-footnotes-state.article

  panic(footnotes)

  format({
    let footnotes-entries = ()

    for (i, note) in footnotes.enumerate() {
      let number = i + 1
      let formatted-number = numbering(numbering-format, number)
      let labels = _local-footnotes-labels(article, footnotes-group-id, number)

      // First add the footnote number
      footnotes-entries.push([
        // Set link color to regular text color, but only for this link, not for links in note text
        #show link: set text(fill: text.fill)
        #heading("")#labels.note
        #link(labels.ref, [#super(formatted-number)])
      ])
      // Then add the corresponding footnote text
      footnotes-entries.push(align(left, note))
    }

    grid(columns: (auto, 1fr), column-gutter: 0.2em, row-gutter: 0.7em, ..footnotes-entries)
  })
}

/// Creates a local footnote with the given text.
/// Can provide more than one note, to separate the footnote references with a comma.
#let local-footnote(note, ..additional-notes, state: none) = {
  // Similar to regular `footnote` support placing a label on a local footnote
  // and then referring to that again at a later point
  let is-label = type(note) == label

  if not is-label {
    state.update(s => {
      s.notes.push(note)
      s
    })
  }

  context {
    let local-footnotes-state = if is-label {
      // TODO: This implementation might be rather error-prone because it also 'works'
      // for labels not attached to local footnotes (?)
      state.at(note)
    } else { state.get() }
    let number = local-footnotes-state.notes.len()
    if is-label {
      // Apparently at the position of the label the state has not been updated yet (?),
      // therefore increase the number
      // TODO: This is rather brittle, it only works because the referenced note itself, which
      //   is not accessible here due to the state not having been updated, is not necessary
      //   when referencing an existing footnote
      number += 1
    }
    let formatted-number = numbering(local-footnotes-state.numbering-format, number)
    let article = local-footnotes-state.article
    let footnotes-group-id = _local-footnotes-counter.get().at(0)
    let labels = _local-footnotes-labels(article, footnotes-group-id, number)

    let color = text.fill
    show link: set text(fill: color)
    // Only add label if this is not itself a label referring to an existing footnote
    let ref-label = if not is-label { labels.ref }

    [
      #heading("") #ref-label
      #link(labels.note, super(formatted-number))
    ]
  }

  for note in additional-notes.pos() {
    super(",")
    local-footnote(note)
  }
}
