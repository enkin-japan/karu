"""Generated M17 inference sample: many distinct names and types."""
from __future__ import annotations

import json
import os
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from enum import Enum
from functools import reduce
from itertools import chain
from pathlib import Path
from typing import Iterable, Optional, TypeVar

T = TypeVar("T")


class InvoiceStatus(Enum):
    DRAFT = "draft_invoice"
    OPEN = "open_invoice"
    PENDING = "pending_invoice"


@dataclass
class Invoice:
    invoice_id: int
    invoice_label: str = "alpha"
    invoice_amount: float = 12.5
    invoice_quantity: int = 3
    invoice_tags: list[str] = field(default_factory=list)
    invoice_created_at: datetime = datetime(2026, 1, 2)
    status: InvoiceStatus = InvoiceStatus.DRAFT

    @property
    def display_invoice(self) -> str:
        return f"Invoice#{self.invoice_id}"

    def to_invoice_dict(self) -> dict[str, object]:
        payload = {"id": self.invoice_id, "status": self.status.value}
        return payload


class InvoiceRepository:
    def __init__(self, root: Path) -> None:
        self.invoice_root = root
        self.invoice_items: dict[int, Invoice] = {}
        self.invoice_history: list[tuple[int, datetime]] = []

    def add_invoice(self, item: Invoice) -> None:
        self.invoice_items[item.invoice_id] = item
        self.invoice_history.append((item.invoice_id, datetime.now()))

    def find_invoice(self, key: int) -> Optional[Invoice]:
        return self.invoice_items.get(key)

    def active_invoices(self) -> list[Invoice]:
        return [x for x in self.invoice_items.values() if x.status is not InvoiceStatus.DRAFT]

    def save_invoices(self) -> Path:
        target = self.invoice_root / "invoices.json"
        rows = [entry.to_invoice_dict() for entry in self.invoice_items.values()]
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return target


def summarize_invoices(items: Iterable[Invoice]) -> dict[str, int]:
    invoice_counter: Counter[str] = Counter()
    for item in items:
        invoice_counter[item.status.value] += 1
    return dict(invoice_counter)


def group_invoices(items: list[Invoice]) -> dict[str, list[Invoice]]:
    invoice_groups: defaultdict[str, list[Invoice]] = defaultdict(list)
    for item in items:
        invoice_groups[item.status.name].append(item)
    return invoice_groups


def parse_invoice_line(line: str) -> Optional[Invoice]:
    match = re.match(r'(\d+)\s+(\w+)', line)
    if match is None:
        return None
    invoice_key = int(match.group(1))
    return Invoice(invoice_id=invoice_key)

class CustomerStatus(Enum):
    DRAFT = "draft_customer"
    OPEN = "open_customer"
    PENDING = "pending_customer"
    SETTLED = "settled_customer"


@dataclass
class Customer:
    customer_id: int
    customer_notes: Optional[str] = None
    customer_weights: dict[str, float] = field(default_factory=dict)
    customer_active: bool = True
    customer_region: str = "apac"
    customer_priority: int = 1
    customer_owner_id: int = 42
    status: CustomerStatus = CustomerStatus.DRAFT

    @property
    def display_customer(self) -> str:
        return f"Customer#{self.customer_id}"

    def to_customer_dict(self) -> dict[str, object]:
        payload = {"id": self.customer_id, "status": self.status.value}
        return payload


class CustomerRepository:
    def __init__(self, root: Path) -> None:
        self.customer_root = root
        self.customer_items: dict[int, Customer] = {}
        self.customer_history: list[tuple[int, datetime]] = []

    def add_customer(self, item: Customer) -> None:
        self.customer_items[item.customer_id] = item
        self.customer_history.append((item.customer_id, datetime.now()))

    def find_customer(self, key: int) -> Optional[Customer]:
        return self.customer_items.get(key)

    def active_customers(self) -> list[Customer]:
        return [x for x in self.customer_items.values() if x.status is not CustomerStatus.DRAFT]

    def save_customers(self) -> Path:
        target = self.customer_root / "customers.json"
        rows = [entry.to_customer_dict() for entry in self.customer_items.values()]
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return target


def summarize_customers(items: Iterable[Customer]) -> dict[str, int]:
    customer_counter: Counter[str] = Counter()
    for item in items:
        customer_counter[item.status.value] += 1
    return dict(customer_counter)


def group_customers(items: list[Customer]) -> dict[str, list[Customer]]:
    customer_groups: defaultdict[str, list[Customer]] = defaultdict(list)
    for item in items:
        customer_groups[item.status.name].append(item)
    return customer_groups


def parse_customer_line(line: str) -> Optional[Customer]:
    match = re.match(r'(\d+)\s+(\w+)', line)
    if match is None:
        return None
    customer_key = int(match.group(1))
    return Customer(customer_id=customer_key)

class ShipmentStatus(Enum):
    DRAFT = "draft_shipment"
    OPEN = "open_shipment"
    PENDING = "pending_shipment"
    SETTLED = "settled_shipment"
    ARCHIVED = "archived_shipment"


@dataclass
class Shipment:
    shipment_id: int
    shipment_owner_id: int = 42
    shipment_source_url: str = "https://example.invalid"
    shipment_label: str = "alpha"
    shipment_amount: float = 12.5
    shipment_quantity: int = 3
    shipment_tags: list[str] = field(default_factory=list)
    shipment_created_at: datetime = datetime(2026, 1, 2)
    status: ShipmentStatus = ShipmentStatus.DRAFT

    @property
    def display_shipment(self) -> str:
        return f"Shipment#{self.shipment_id}"

    def to_shipment_dict(self) -> dict[str, object]:
        payload = {"id": self.shipment_id, "status": self.status.value}
        return payload


class ShipmentRepository:
    def __init__(self, root: Path) -> None:
        self.shipment_root = root
        self.shipment_items: dict[int, Shipment] = {}
        self.shipment_history: list[tuple[int, datetime]] = []

    def add_shipment(self, item: Shipment) -> None:
        self.shipment_items[item.shipment_id] = item
        self.shipment_history.append((item.shipment_id, datetime.now()))

    def find_shipment(self, key: int) -> Optional[Shipment]:
        return self.shipment_items.get(key)

    def active_shipments(self) -> list[Shipment]:
        return [x for x in self.shipment_items.values() if x.status is not ShipmentStatus.DRAFT]

    def save_shipments(self) -> Path:
        target = self.shipment_root / "shipments.json"
        rows = [entry.to_shipment_dict() for entry in self.shipment_items.values()]
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return target


def summarize_shipments(items: Iterable[Shipment]) -> dict[str, int]:
    shipment_counter: Counter[str] = Counter()
    for item in items:
        shipment_counter[item.status.value] += 1
    return dict(shipment_counter)


def group_shipments(items: list[Shipment]) -> dict[str, list[Shipment]]:
    shipment_groups: defaultdict[str, list[Shipment]] = defaultdict(list)
    for item in items:
        shipment_groups[item.status.name].append(item)
    return shipment_groups


def parse_shipment_line(line: str) -> Optional[Shipment]:
    match = re.match(r'(\d+)\s+(\w+)', line)
    if match is None:
        return None
    shipment_key = int(match.group(1))
    return Shipment(shipment_id=shipment_key)

class WarehouseStatus(Enum):
    DRAFT = "draft_warehouse"
    OPEN = "open_warehouse"
    PENDING = "pending_warehouse"


@dataclass
class Warehouse:
    warehouse_id: int
    warehouse_tags: list[str] = field(default_factory=list)
    warehouse_created_at: datetime = datetime(2026, 1, 2)
    warehouse_notes: Optional[str] = None
    warehouse_weights: dict[str, float] = field(default_factory=dict)
    warehouse_active: bool = True
    status: WarehouseStatus = WarehouseStatus.DRAFT

    @property
    def display_warehouse(self) -> str:
        return f"Warehouse#{self.warehouse_id}"

    def to_warehouse_dict(self) -> dict[str, object]:
        payload = {"id": self.warehouse_id, "status": self.status.value}
        return payload


class WarehouseRepository:
    def __init__(self, root: Path) -> None:
        self.warehouse_root = root
        self.warehouse_items: dict[int, Warehouse] = {}
        self.warehouse_history: list[tuple[int, datetime]] = []

    def add_warehouse(self, item: Warehouse) -> None:
        self.warehouse_items[item.warehouse_id] = item
        self.warehouse_history.append((item.warehouse_id, datetime.now()))

    def find_warehouse(self, key: int) -> Optional[Warehouse]:
        return self.warehouse_items.get(key)

    def active_warehouses(self) -> list[Warehouse]:
        return [x for x in self.warehouse_items.values() if x.status is not WarehouseStatus.DRAFT]

    def save_warehouses(self) -> Path:
        target = self.warehouse_root / "warehouses.json"
        rows = [entry.to_warehouse_dict() for entry in self.warehouse_items.values()]
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return target


def summarize_warehouses(items: Iterable[Warehouse]) -> dict[str, int]:
    warehouse_counter: Counter[str] = Counter()
    for item in items:
        warehouse_counter[item.status.value] += 1
    return dict(warehouse_counter)


def group_warehouses(items: list[Warehouse]) -> dict[str, list[Warehouse]]:
    warehouse_groups: defaultdict[str, list[Warehouse]] = defaultdict(list)
    for item in items:
        warehouse_groups[item.status.name].append(item)
    return warehouse_groups


def parse_warehouse_line(line: str) -> Optional[Warehouse]:
    match = re.match(r'(\d+)\s+(\w+)', line)
    if match is None:
        return None
    warehouse_key = int(match.group(1))
    return Warehouse(warehouse_id=warehouse_key)

class LedgerStatus(Enum):
    DRAFT = "draft_ledger"
    OPEN = "open_ledger"
    PENDING = "pending_ledger"
    SETTLED = "settled_ledger"


@dataclass
class Ledger:
    ledger_id: int
    ledger_region: str = "apac"
    ledger_priority: int = 1
    ledger_owner_id: int = 42
    ledger_source_url: str = "https://example.invalid"
    ledger_label: str = "alpha"
    ledger_amount: float = 12.5
    status: LedgerStatus = LedgerStatus.DRAFT

    @property
    def display_ledger(self) -> str:
        return f"Ledger#{self.ledger_id}"

    def to_ledger_dict(self) -> dict[str, object]:
        payload = {"id": self.ledger_id, "status": self.status.value}
        return payload


class LedgerRepository:
    def __init__(self, root: Path) -> None:
        self.ledger_root = root
        self.ledger_items: dict[int, Ledger] = {}
        self.ledger_history: list[tuple[int, datetime]] = []

    def add_ledger(self, item: Ledger) -> None:
        self.ledger_items[item.ledger_id] = item
        self.ledger_history.append((item.ledger_id, datetime.now()))

    def find_ledger(self, key: int) -> Optional[Ledger]:
        return self.ledger_items.get(key)

    def active_ledgers(self) -> list[Ledger]:
        return [x for x in self.ledger_items.values() if x.status is not LedgerStatus.DRAFT]

    def save_ledgers(self) -> Path:
        target = self.ledger_root / "ledgers.json"
        rows = [entry.to_ledger_dict() for entry in self.ledger_items.values()]
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return target


def summarize_ledgers(items: Iterable[Ledger]) -> dict[str, int]:
    ledger_counter: Counter[str] = Counter()
    for item in items:
        ledger_counter[item.status.value] += 1
    return dict(ledger_counter)


def group_ledgers(items: list[Ledger]) -> dict[str, list[Ledger]]:
    ledger_groups: defaultdict[str, list[Ledger]] = defaultdict(list)
    for item in items:
        ledger_groups[item.status.name].append(item)
    return ledger_groups


def parse_ledger_line(line: str) -> Optional[Ledger]:
    match = re.match(r'(\d+)\s+(\w+)', line)
    if match is None:
        return None
    ledger_key = int(match.group(1))
    return Ledger(ledger_id=ledger_key)

class SupplierStatus(Enum):
    DRAFT = "draft_supplier"
    OPEN = "open_supplier"
    PENDING = "pending_supplier"
    SETTLED = "settled_supplier"
    ARCHIVED = "archived_supplier"


@dataclass
class Supplier:
    supplier_id: int
    supplier_amount: float = 12.5
    supplier_quantity: int = 3
    supplier_tags: list[str] = field(default_factory=list)
    supplier_created_at: datetime = datetime(2026, 1, 2)
    supplier_notes: Optional[str] = None
    supplier_weights: dict[str, float] = field(default_factory=dict)
    supplier_active: bool = True
    status: SupplierStatus = SupplierStatus.DRAFT

    @property
    def display_supplier(self) -> str:
        return f"Supplier#{self.supplier_id}"

    def to_supplier_dict(self) -> dict[str, object]:
        payload = {"id": self.supplier_id, "status": self.status.value}
        return payload


class SupplierRepository:
    def __init__(self, root: Path) -> None:
        self.supplier_root = root
        self.supplier_items: dict[int, Supplier] = {}
        self.supplier_history: list[tuple[int, datetime]] = []

    def add_supplier(self, item: Supplier) -> None:
        self.supplier_items[item.supplier_id] = item
        self.supplier_history.append((item.supplier_id, datetime.now()))

    def find_supplier(self, key: int) -> Optional[Supplier]:
        return self.supplier_items.get(key)

    def active_suppliers(self) -> list[Supplier]:
        return [x for x in self.supplier_items.values() if x.status is not SupplierStatus.DRAFT]

    def save_suppliers(self) -> Path:
        target = self.supplier_root / "suppliers.json"
        rows = [entry.to_supplier_dict() for entry in self.supplier_items.values()]
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return target


def summarize_suppliers(items: Iterable[Supplier]) -> dict[str, int]:
    supplier_counter: Counter[str] = Counter()
    for item in items:
        supplier_counter[item.status.value] += 1
    return dict(supplier_counter)


def group_suppliers(items: list[Supplier]) -> dict[str, list[Supplier]]:
    supplier_groups: defaultdict[str, list[Supplier]] = defaultdict(list)
    for item in items:
        supplier_groups[item.status.name].append(item)
    return supplier_groups


def parse_supplier_line(line: str) -> Optional[Supplier]:
    match = re.match(r'(\d+)\s+(\w+)', line)
    if match is None:
        return None
    supplier_key = int(match.group(1))
    return Supplier(supplier_id=supplier_key)

class PaymentStatus(Enum):
    DRAFT = "draft_payment"
    OPEN = "open_payment"
    PENDING = "pending_payment"


@dataclass
class Payment:
    payment_id: int
    payment_weights: dict[str, float] = field(default_factory=dict)
    payment_active: bool = True
    payment_region: str = "apac"
    payment_priority: int = 1
    payment_owner_id: int = 42
    status: PaymentStatus = PaymentStatus.DRAFT

    @property
    def display_payment(self) -> str:
        return f"Payment#{self.payment_id}"

    def to_payment_dict(self) -> dict[str, object]:
        payload = {"id": self.payment_id, "status": self.status.value}
        return payload


class PaymentRepository:
    def __init__(self, root: Path) -> None:
        self.payment_root = root
        self.payment_items: dict[int, Payment] = {}
        self.payment_history: list[tuple[int, datetime]] = []

    def add_payment(self, item: Payment) -> None:
        self.payment_items[item.payment_id] = item
        self.payment_history.append((item.payment_id, datetime.now()))

    def find_payment(self, key: int) -> Optional[Payment]:
        return self.payment_items.get(key)

    def active_payments(self) -> list[Payment]:
        return [x for x in self.payment_items.values() if x.status is not PaymentStatus.DRAFT]

    def save_payments(self) -> Path:
        target = self.payment_root / "payments.json"
        rows = [entry.to_payment_dict() for entry in self.payment_items.values()]
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return target


def summarize_payments(items: Iterable[Payment]) -> dict[str, int]:
    payment_counter: Counter[str] = Counter()
    for item in items:
        payment_counter[item.status.value] += 1
    return dict(payment_counter)


def group_payments(items: list[Payment]) -> dict[str, list[Payment]]:
    payment_groups: defaultdict[str, list[Payment]] = defaultdict(list)
    for item in items:
        payment_groups[item.status.name].append(item)
    return payment_groups


def parse_payment_line(line: str) -> Optional[Payment]:
    match = re.match(r'(\d+)\s+(\w+)', line)
    if match is None:
        return None
    payment_key = int(match.group(1))
    return Payment(payment_id=payment_key)

class RefundStatus(Enum):
    DRAFT = "draft_refund"
    OPEN = "open_refund"
    PENDING = "pending_refund"
    SETTLED = "settled_refund"


@dataclass
class Refund:
    refund_id: int
    refund_source_url: str = "https://example.invalid"
    refund_label: str = "alpha"
    refund_amount: float = 12.5
    refund_quantity: int = 3
    refund_tags: list[str] = field(default_factory=list)
    refund_created_at: datetime = datetime(2026, 1, 2)
    status: RefundStatus = RefundStatus.DRAFT

    @property
    def display_refund(self) -> str:
        return f"Refund#{self.refund_id}"

    def to_refund_dict(self) -> dict[str, object]:
        payload = {"id": self.refund_id, "status": self.status.value}
        return payload


class RefundRepository:
    def __init__(self, root: Path) -> None:
        self.refund_root = root
        self.refund_items: dict[int, Refund] = {}
        self.refund_history: list[tuple[int, datetime]] = []

    def add_refund(self, item: Refund) -> None:
        self.refund_items[item.refund_id] = item
        self.refund_history.append((item.refund_id, datetime.now()))

    def find_refund(self, key: int) -> Optional[Refund]:
        return self.refund_items.get(key)

    def active_refunds(self) -> list[Refund]:
        return [x for x in self.refund_items.values() if x.status is not RefundStatus.DRAFT]

    def save_refunds(self) -> Path:
        target = self.refund_root / "refunds.json"
        rows = [entry.to_refund_dict() for entry in self.refund_items.values()]
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return target


def summarize_refunds(items: Iterable[Refund]) -> dict[str, int]:
    refund_counter: Counter[str] = Counter()
    for item in items:
        refund_counter[item.status.value] += 1
    return dict(refund_counter)


def group_refunds(items: list[Refund]) -> dict[str, list[Refund]]:
    refund_groups: defaultdict[str, list[Refund]] = defaultdict(list)
    for item in items:
        refund_groups[item.status.name].append(item)
    return refund_groups


def parse_refund_line(line: str) -> Optional[Refund]:
    match = re.match(r'(\d+)\s+(\w+)', line)
    if match is None:
        return None
    refund_key = int(match.group(1))
    return Refund(refund_id=refund_key)

class CouponStatus(Enum):
    DRAFT = "draft_coupon"
    OPEN = "open_coupon"
    PENDING = "pending_coupon"
    SETTLED = "settled_coupon"
    ARCHIVED = "archived_coupon"


@dataclass
class Coupon:
    coupon_id: int
    coupon_created_at: datetime = datetime(2026, 1, 2)
    coupon_notes: Optional[str] = None
    coupon_weights: dict[str, float] = field(default_factory=dict)
    coupon_active: bool = True
    coupon_region: str = "apac"
    coupon_priority: int = 1
    coupon_owner_id: int = 42
    status: CouponStatus = CouponStatus.DRAFT

    @property
    def display_coupon(self) -> str:
        return f"Coupon#{self.coupon_id}"

    def to_coupon_dict(self) -> dict[str, object]:
        payload = {"id": self.coupon_id, "status": self.status.value}
        return payload


class CouponRepository:
    def __init__(self, root: Path) -> None:
        self.coupon_root = root
        self.coupon_items: dict[int, Coupon] = {}
        self.coupon_history: list[tuple[int, datetime]] = []

    def add_coupon(self, item: Coupon) -> None:
        self.coupon_items[item.coupon_id] = item
        self.coupon_history.append((item.coupon_id, datetime.now()))

    def find_coupon(self, key: int) -> Optional[Coupon]:
        return self.coupon_items.get(key)

    def active_coupons(self) -> list[Coupon]:
        return [x for x in self.coupon_items.values() if x.status is not CouponStatus.DRAFT]

    def save_coupons(self) -> Path:
        target = self.coupon_root / "coupons.json"
        rows = [entry.to_coupon_dict() for entry in self.coupon_items.values()]
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return target


def summarize_coupons(items: Iterable[Coupon]) -> dict[str, int]:
    coupon_counter: Counter[str] = Counter()
    for item in items:
        coupon_counter[item.status.value] += 1
    return dict(coupon_counter)


def group_coupons(items: list[Coupon]) -> dict[str, list[Coupon]]:
    coupon_groups: defaultdict[str, list[Coupon]] = defaultdict(list)
    for item in items:
        coupon_groups[item.status.name].append(item)
    return coupon_groups


def parse_coupon_line(line: str) -> Optional[Coupon]:
    match = re.match(r'(\d+)\s+(\w+)', line)
    if match is None:
        return None
    coupon_key = int(match.group(1))
    return Coupon(coupon_id=coupon_key)

class VoucherStatus(Enum):
    DRAFT = "draft_voucher"
    OPEN = "open_voucher"
    PENDING = "pending_voucher"


@dataclass
class Voucher:
    voucher_id: int
    voucher_priority: int = 1
    voucher_owner_id: int = 42
    voucher_source_url: str = "https://example.invalid"
    voucher_label: str = "alpha"
    voucher_amount: float = 12.5
    status: VoucherStatus = VoucherStatus.DRAFT

    @property
    def display_voucher(self) -> str:
        return f"Voucher#{self.voucher_id}"

    def to_voucher_dict(self) -> dict[str, object]:
        payload = {"id": self.voucher_id, "status": self.status.value}
        return payload


class VoucherRepository:
    def __init__(self, root: Path) -> None:
        self.voucher_root = root
        self.voucher_items: dict[int, Voucher] = {}
        self.voucher_history: list[tuple[int, datetime]] = []

    def add_voucher(self, item: Voucher) -> None:
        self.voucher_items[item.voucher_id] = item
        self.voucher_history.append((item.voucher_id, datetime.now()))

    def find_voucher(self, key: int) -> Optional[Voucher]:
        return self.voucher_items.get(key)

    def active_vouchers(self) -> list[Voucher]:
        return [x for x in self.voucher_items.values() if x.status is not VoucherStatus.DRAFT]

    def save_vouchers(self) -> Path:
        target = self.voucher_root / "vouchers.json"
        rows = [entry.to_voucher_dict() for entry in self.voucher_items.values()]
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return target


def summarize_vouchers(items: Iterable[Voucher]) -> dict[str, int]:
    voucher_counter: Counter[str] = Counter()
    for item in items:
        voucher_counter[item.status.value] += 1
    return dict(voucher_counter)


def group_vouchers(items: list[Voucher]) -> dict[str, list[Voucher]]:
    voucher_groups: defaultdict[str, list[Voucher]] = defaultdict(list)
    for item in items:
        voucher_groups[item.status.name].append(item)
    return voucher_groups


def parse_voucher_line(line: str) -> Optional[Voucher]:
    match = re.match(r'(\d+)\s+(\w+)', line)
    if match is None:
        return None
    voucher_key = int(match.group(1))
    return Voucher(voucher_id=voucher_key)

class CourierStatus(Enum):
    DRAFT = "draft_courier"
    OPEN = "open_courier"
    PENDING = "pending_courier"
    SETTLED = "settled_courier"


@dataclass
class Courier:
    courier_id: int
    courier_quantity: int = 3
    courier_tags: list[str] = field(default_factory=list)
    courier_created_at: datetime = datetime(2026, 1, 2)
    courier_notes: Optional[str] = None
    courier_weights: dict[str, float] = field(default_factory=dict)
    courier_active: bool = True
    status: CourierStatus = CourierStatus.DRAFT

    @property
    def display_courier(self) -> str:
        return f"Courier#{self.courier_id}"

    def to_courier_dict(self) -> dict[str, object]:
        payload = {"id": self.courier_id, "status": self.status.value}
        return payload


class CourierRepository:
    def __init__(self, root: Path) -> None:
        self.courier_root = root
        self.courier_items: dict[int, Courier] = {}
        self.courier_history: list[tuple[int, datetime]] = []

    def add_courier(self, item: Courier) -> None:
        self.courier_items[item.courier_id] = item
        self.courier_history.append((item.courier_id, datetime.now()))

    def find_courier(self, key: int) -> Optional[Courier]:
        return self.courier_items.get(key)

    def active_couriers(self) -> list[Courier]:
        return [x for x in self.courier_items.values() if x.status is not CourierStatus.DRAFT]

    def save_couriers(self) -> Path:
        target = self.courier_root / "couriers.json"
        rows = [entry.to_courier_dict() for entry in self.courier_items.values()]
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return target


def summarize_couriers(items: Iterable[Courier]) -> dict[str, int]:
    courier_counter: Counter[str] = Counter()
    for item in items:
        courier_counter[item.status.value] += 1
    return dict(courier_counter)


def group_couriers(items: list[Courier]) -> dict[str, list[Courier]]:
    courier_groups: defaultdict[str, list[Courier]] = defaultdict(list)
    for item in items:
        courier_groups[item.status.name].append(item)
    return courier_groups


def parse_courier_line(line: str) -> Optional[Courier]:
    match = re.match(r'(\d+)\s+(\w+)', line)
    if match is None:
        return None
    courier_key = int(match.group(1))
    return Courier(courier_id=courier_key)

class ParcelStatus(Enum):
    DRAFT = "draft_parcel"
    OPEN = "open_parcel"
    PENDING = "pending_parcel"
    SETTLED = "settled_parcel"
    ARCHIVED = "archived_parcel"


@dataclass
class Parcel:
    parcel_id: int
    parcel_active: bool = True
    parcel_region: str = "apac"
    parcel_priority: int = 1
    parcel_owner_id: int = 42
    parcel_source_url: str = "https://example.invalid"
    parcel_label: str = "alpha"
    parcel_amount: float = 12.5
    status: ParcelStatus = ParcelStatus.DRAFT

    @property
    def display_parcel(self) -> str:
        return f"Parcel#{self.parcel_id}"

    def to_parcel_dict(self) -> dict[str, object]:
        payload = {"id": self.parcel_id, "status": self.status.value}
        return payload


class ParcelRepository:
    def __init__(self, root: Path) -> None:
        self.parcel_root = root
        self.parcel_items: dict[int, Parcel] = {}
        self.parcel_history: list[tuple[int, datetime]] = []

    def add_parcel(self, item: Parcel) -> None:
        self.parcel_items[item.parcel_id] = item
        self.parcel_history.append((item.parcel_id, datetime.now()))

    def find_parcel(self, key: int) -> Optional[Parcel]:
        return self.parcel_items.get(key)

    def active_parcels(self) -> list[Parcel]:
        return [x for x in self.parcel_items.values() if x.status is not ParcelStatus.DRAFT]

    def save_parcels(self) -> Path:
        target = self.parcel_root / "parcels.json"
        rows = [entry.to_parcel_dict() for entry in self.parcel_items.values()]
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return target


def summarize_parcels(items: Iterable[Parcel]) -> dict[str, int]:
    parcel_counter: Counter[str] = Counter()
    for item in items:
        parcel_counter[item.status.value] += 1
    return dict(parcel_counter)


def group_parcels(items: list[Parcel]) -> dict[str, list[Parcel]]:
    parcel_groups: defaultdict[str, list[Parcel]] = defaultdict(list)
    for item in items:
        parcel_groups[item.status.name].append(item)
    return parcel_groups


def parse_parcel_line(line: str) -> Optional[Parcel]:
    match = re.match(r'(\d+)\s+(\w+)', line)
    if match is None:
        return None
    parcel_key = int(match.group(1))
    return Parcel(parcel_id=parcel_key)


def first_or_default(values: list[T], default: T) -> T:
    return values[0] if values else default


def build_report(root: Path) -> str:
    report_lines: list[str] = []
    deadline = datetime.now() + timedelta(days=7)
    env_name = os.environ.get("KARU_SAMPLE_ENV", "dev")
    invoice_repo = InvoiceRepository(root)
    invoice_summary = summarize_invoices(invoice_repo.active_invoices())
    report_lines.append(f"invoice: {invoice_summary} until {deadline:%Y-%m-%d} on {env_name}")
    customer_repo = CustomerRepository(root)
    customer_summary = summarize_customers(customer_repo.active_customers())
    report_lines.append(f"customer: {customer_summary} until {deadline:%Y-%m-%d} on {env_name}")
    shipment_repo = ShipmentRepository(root)
    shipment_summary = summarize_shipments(shipment_repo.active_shipments())
    report_lines.append(f"shipment: {shipment_summary} until {deadline:%Y-%m-%d} on {env_name}")
    warehouse_repo = WarehouseRepository(root)
    warehouse_summary = summarize_warehouses(warehouse_repo.active_warehouses())
    report_lines.append(f"warehouse: {warehouse_summary} until {deadline:%Y-%m-%d} on {env_name}")
    ledger_repo = LedgerRepository(root)
    ledger_summary = summarize_ledgers(ledger_repo.active_ledgers())
    report_lines.append(f"ledger: {ledger_summary} until {deadline:%Y-%m-%d} on {env_name}")
    supplier_repo = SupplierRepository(root)
    supplier_summary = summarize_suppliers(supplier_repo.active_suppliers())
    report_lines.append(f"supplier: {supplier_summary} until {deadline:%Y-%m-%d} on {env_name}")
    payment_repo = PaymentRepository(root)
    payment_summary = summarize_payments(payment_repo.active_payments())
    report_lines.append(f"payment: {payment_summary} until {deadline:%Y-%m-%d} on {env_name}")
    refund_repo = RefundRepository(root)
    refund_summary = summarize_refunds(refund_repo.active_refunds())
    report_lines.append(f"refund: {refund_summary} until {deadline:%Y-%m-%d} on {env_name}")
    coupon_repo = CouponRepository(root)
    coupon_summary = summarize_coupons(coupon_repo.active_coupons())
    report_lines.append(f"coupon: {coupon_summary} until {deadline:%Y-%m-%d} on {env_name}")
    voucher_repo = VoucherRepository(root)
    voucher_summary = summarize_vouchers(voucher_repo.active_vouchers())
    report_lines.append(f"voucher: {voucher_summary} until {deadline:%Y-%m-%d} on {env_name}")
    courier_repo = CourierRepository(root)
    courier_summary = summarize_couriers(courier_repo.active_couriers())
    report_lines.append(f"courier: {courier_summary} until {deadline:%Y-%m-%d} on {env_name}")
    parcel_repo = ParcelRepository(root)
    parcel_summary = summarize_parcels(parcel_repo.active_parcels())
    report_lines.append(f"parcel: {parcel_summary} until {deadline:%Y-%m-%d} on {env_name}")
    flat = list(chain.from_iterable(line.split(":") for line in report_lines))
    total = reduce(lambda acc, part: acc + len(part), flat, 0)
    return "\n".join(report_lines) + f"\n{total}"

