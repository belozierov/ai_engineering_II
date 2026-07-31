# Checkout 5xx triage

Source ID: `rb-checkout-5xx`

When `checkout-service` 5xx errors rise immediately after a deploy:

1. Confirm the deploy ID and error-rate window in monitoring.
2. Search checkout logs for a repeated dependency and elapsed time.
3. Compare the dependency latency with `tax_service_timeout_seconds`.
4. If tax-service timeouts dominate, roll back the synthetic checkout deploy or restore the previously validated timeout and retry policy.
5. Confirm health and error rate recover before closing the incident.

Do not infer customer impact or execute a rollback without current monitoring and repository evidence.
