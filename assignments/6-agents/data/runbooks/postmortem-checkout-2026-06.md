# Synthetic postmortem: checkout timeout regression

Source ID: `pm-checkout-timeout-2026-06`

In the June synthetic exercise, checkout error rate increased after a configuration deploy reduced the tax-service timeout while retries remained disabled. Health checks stayed responsive, so health alone was a dead end.

Responders correlated checkout logs, deploy metadata, and the dependency-timeout runbook. Rolling back the configuration restored the prior deadline. The follow-up added a deploy-time check that compares dependency deadlines with the observed synthetic latency budget.
