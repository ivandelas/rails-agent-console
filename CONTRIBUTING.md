# Contributing

Thanks for taking the time to improve `rails_agent_console`.

## Reporting a bug

Open an issue at <https://github.com/blaz1988/rails-agent-console/issues> with:

- the Ruby, Rails and gem versions, and the provider and model you use;
- the question you asked, the query the gem proposed, and what happened;
- the output of `bundle exec rails-agent doctor`.

Please leave out API keys and anything from your data you wouldn't post publicly. For a
security problem, follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Making a change

```bash
git clone git@github.com:blaz1988/rails-agent-console.git
cd rails-agent-console
bin/setup
bundle exec rake    # specs and RuboCop
```

1. Fork the repository and create a branch from `main`.
2. Add a spec for the change. Most of the suite is table-driven, so a new case is often one line.
3. Run `bundle exec rake`. If the change touches schema introspection or console integration,
   run `bin/matrix` as well, which covers every supported Ruby and Rails combination.
4. Add a line to the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md).
5. Open a pull request that explains what changed and why.

## A note on the approach

When a model keeps making the same mistake, the gem fixes it in Ruby (the rewriter, the
validator or the diagnosis hints) rather than adding another line to the prompt. A prompt
line is sent with every question and costs tokens forever; a fix in code is free and can be
tested. Pull requests in that spirit are especially welcome.

## Code of conduct

Be kind and assume good intent. Harassment or abuse of any kind isn't tolerated in issues,
pull requests or any other project space.
