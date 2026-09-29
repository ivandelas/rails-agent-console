# Security policy

`rails_agent_console` runs code that a language model proposes, so its safety checks matter.
If you find a way around them, we want to know.

## Supported versions

| Version | Supported |
| --- | :---: |
| 0.1.x | ✓ |

## Reporting a vulnerability

Please **don't** open a public issue. Email
[ivan.blazevic@rubycode.co](mailto:ivan.blazevic@rubycode.co) with:

- the gem version, and your Ruby and Rails versions;
- the code, or the question, that got past the validator;
- what it was able to do.

You'll get a reply within three working days. Once a fix is released, we're happy to credit
you in the changelog.

## In scope

- Generated code that writes to the database in read-only mode.
- Code that reaches the shell, the file system, `ENV`, `eval` or a raw connection.
- A credential column read despite the sensitive-column check.
- An API key written to disk or printed when it shouldn't be.
