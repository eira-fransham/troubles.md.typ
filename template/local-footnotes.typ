#let _local-footnotes-state = state("local-footnotes", (
  numbering-format: "a",
  notes: (),
))
/// (internal) unique ID per group of local footnotes
#let _local-footnotes-counter = counter("local-footnotes")

/// Changes the setup for local footnotes
#let local-footnotes-setup(numbering-format: "a") = {
  context {
    if _local-footnotes-state.get().notes.len() > 0 {
      panic("cannot change local-footnotes-setup when there are not yet shown footnotes")
    }
  }

  _local-footnotes-state.update(s => {
    s.numbering-format = numbering-format
    s
  })
}

/// (internal) Creates labels for linking from ref to note and vice versa
#let _local-footnotes-labels(footnotes-group-id, index) = {
  (
    ref: label("ft-ref-" + str(footnotes-group-id) + "-" + str(index)),
    note: label("ft-note-" + str(footnotes-group-id) + "-" + str(index)),
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
#let local-footnotes-show(format: _local-footnotes-format) = context {
  let local-footnotes-state = _local-footnotes-state.get()
  let footnotes = local-footnotes-state.notes
  if footnotes.len() == 0 {
    return
  }
  local-footnotes-state.notes = ()
  _local-footnotes-state.update(local-footnotes-state)
  _local-footnotes-counter.step()
  let footnotes-group-id = _local-footnotes-counter.get().at(0)
  let numbering-format = local-footnotes-state.numbering-format

  let footnotes-entries = ()

  html.elem("section", attrs: (class: "footnotes", role: "doc-endnotes"))[
    #html.elem("hr")

    #html.elem("ol", [
      #for (i, note) in footnotes.enumerate() [
        #let number = i + 1
        #let formatted-number = numbering(numbering-format, number)
        #let labels = _local-footnotes-labels(footnotes-group-id, number)

        // Then add the corresponding footnote text
        #html.elem("li")[
          #note
          #html.elem("div", attrs: (class: "ft-return-link"))[
            #link(labels.ref, [↩︎])
          ]
        ]#labels.note
      ]
    ])
  ]
}

/// Creates a local footnote with the given text.
/// Can provide more than one note, to separate the footnote references with a comma.
#let local-footnote(note, ..additional-notes) = {
  // Similar to regular `footnote` support placing a label on a local footnote
  // and then referring to that again at a later point
  let is-label = type(note) == label

  if not is-label {
    _local-footnotes-state.update(s => {
      s.notes.push(note)
      s
    })
  }

  context {
    let local-footnotes-state = if is-label {
      // TODO: This implementation might be rather error-prone because it also 'works'
      // for labels not attached to local footnotes (?)
      _local-footnotes-state.at(note)
    } else { _local-footnotes-state.get() }
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
    let footnotes-group-id = _local-footnotes-counter.get().at(0)
    let labels = _local-footnotes-labels(footnotes-group-id, number)

    let color = text.fill
    show link: set text(fill: color)
    // Only add label if this is not itself a label referring to an existing footnote
    let ref-label = if not is-label { labels.ref }
    // Use `weak: true` to collapse space, similar to built-in `footnote`
    [
      #link(labels.note, super(formatted-number))#ref-label
    ]
  }

  for note in additional-notes.pos() {
    super(",")
    local-footnote(note)
  }
}
