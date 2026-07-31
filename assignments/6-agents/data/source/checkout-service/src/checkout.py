"""Synthetic checkout handler used only by the AI Engineering course fixture."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Checkout:
    order_id: str
    subtotal_cents: int


def calculate_total(checkout: Checkout, tax_client: object) -> int:
    """Return the subtotal plus tax from the injected dependency."""

    tax_cents = tax_client.quote(checkout.order_id, checkout.subtotal_cents)
    return checkout.subtotal_cents + tax_cents
