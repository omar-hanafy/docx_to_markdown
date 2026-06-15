This span[^9] should have a custom style ([link](http://example.com/)), but the text after the comma shouldn’t, nor should the link.

The contents of this div should have a custom style, but [this link should not](http://example.com/).

## This header should not have the div’s custom style

> This blockquote should not.

```
# This code block should not.
```

But this paragraph should.[^11]

This should have MyInnerStyle.

### This heading should not

This should have MyOuterStyle, but the following elision should have its own style. ...

> This blockquote should include **bold text with an elision: ...**

---

[^9]:  Neither footnote nor footnote reference should get a custom style from its span.
[^11]:  Neither footnote nor footnote reference should get a custom style from its div.
