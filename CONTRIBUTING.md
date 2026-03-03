# Contributing to Femux

Thanks for contributing.

## Development Setup

1. Install Flutter stable.
2. Clone the repository.
3. Run:

```bash
flutter pub get
flutter analyze
flutter test
```

## Workflow

- Create a feature branch from `main`.
- Keep PRs focused and small.
- Add or update tests when behavior changes.
- Ensure `flutter analyze` passes before opening a PR.

## Pull Request Checklist

- [ ] Builds and runs locally
- [ ] Analyzer passes
- [ ] Tests pass
- [ ] README or docs updated (if needed)
- [ ] No unrelated refactors

## Code Style

- Follow existing project style.
- Prefer minimal, targeted changes.
- Avoid adding dependencies without strong reason.
