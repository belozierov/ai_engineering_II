# Dependency timeout diagnosis

Source ID: `rb-dependency-timeouts`

Repeated upstream timeouts should be grouped by dependency, deploy, and configured deadline. A low client deadline with retries disabled can turn a modest latency increase into checkout 5xx errors.

For `tax-service`, compare the configured deadline with the `elapsed_ms` values in checkout logs. Validate the relationship using both current monitoring and the checked-out service configuration. Prefer a rollback to a known synthetic configuration over an unbounded timeout increase.
