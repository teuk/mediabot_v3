# Pull request

Thank you for contributing to Mediabot v3.

Please provide enough information to understand, review and safely test the proposed change.

## Summary

Describe what this Pull Request changes and why it is needed.

## Related Issue or Discussion

Link the related Issue or Discussion when applicable.

```text
Closes #
Related to #
```

## Type of change

Select all that apply:

* [ ] Bug fix
* [ ] New feature
* [ ] Existing command improvement
* [ ] Plugin or scripting change
* [ ] Documentation
* [ ] Tests
* [ ] Installation or configuration
* [ ] Monitoring, metrics or logging
* [ ] Refactoring with no intended behavior change
* [ ] Other

## Behavior and compatibility

Describe any visible or technical impact.

* Does this change existing IRC commands or responses?
* Does this add or modify configuration options?
* Does this affect existing installations?
* Does this require a new dependency?
* Could this change runtime behavior or performance?

### Database impact

Select one:

* [ ] No database impact
* [ ] Queries changed, but the schema is unchanged
* [ ] Database schema or migration change
* [ ] I am not sure

Database schema changes must be discussed before implementation.

## Testing performed

List the exact commands that were executed.

```text
Paste syntax checks and test commands here.
```

Provide the corresponding result:

```text
Paste a concise test result here.
```

When relevant, include:

* Perl syntax checks;
* targeted tests for the modified feature;
* IRC commands tested;
* expected and observed bot responses;
* sanitized runtime logs.

Do not claim that a test passed unless it was actually executed.

If some tests were not run, explain why:

```text
Not run:
Reason:
```

## Runtime validation

Select the most appropriate statements:

* [ ] This change has no runtime impact
* [ ] Tested on a dedicated development instance
* [ ] Tested with the relevant IRC command or event
* [ ] Tested with an existing configuration
* [ ] Tested with an existing database
* [ ] Runtime validation was not possible

## Documentation

Select one:

* [ ] Documentation was updated
* [ ] No documentation change is required
* [ ] Documentation still needs to be written

## Security and privacy

Confirm that:

* [ ] No password, API key, token, cookie or private key is included
* [ ] Logs and configuration examples are sanitized
* [ ] No private infrastructure or personal information is exposed
* [ ] External input is validated where applicable
* [ ] New network operations include appropriate timeout and error handling

## Final checklist

Before submitting this Pull Request, confirm that:

* [ ] The change is focused on one topic
* [ ] Unrelated files or formatting changes are not included
* [ ] Existing behavior is preserved unless the change was explicitly discussed
* [ ] Modified Perl files pass syntax checks
* [ ] Relevant tests pass
* [ ] `git diff --check` reports no whitespace errors
* [ ] Configuration changes are backward-compatible when possible
* [ ] User-visible changes are documented
* [ ] Database changes were discussed beforehand
* [ ] The testing section contains the exact commands that were executed

## Additional context

Add screenshots, sanitized logs, example IRC output or other useful information.
