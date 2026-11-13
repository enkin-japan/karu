// Generated M17 inference sample: many distinct names and types.

type Identifier = number;
type Maybe<T> = T | undefined;

interface Page<T> {
  items: T[];
  cursor: Maybe<string>;
  total: number;
}

function firstOrDefault<T>(values: T[], fallback: T): T {
  return values.length > 0 ? values[0] : fallback;
}

export enum InvoiceStatus {
  Draft = "draft_invoice",
  Open = "open_invoice",
  Pending = "pending_invoice",
}

export interface InvoiceRecord {
  invoiceId: Identifier;
  invoiceLabel: string;
  invoiceAmount: number;
  invoiceQuantity: number;
  invoiceTags: string[];
  invoiceCreatedAt: Date;
  status: InvoiceStatus;
}

export class InvoiceStore {
  private readonly invoiceItems = new Map<Identifier, InvoiceRecord>();
  private invoiceLog: Array<[Identifier, Date]> = [];

  constructor(private readonly invoiceEndpoint: string) {}

  addInvoice(record: InvoiceRecord): void {
    this.invoiceItems.set(record.invoiceId, record);
    this.invoiceLog.push([record.invoiceId, new Date()]);
  }

  findInvoice(key: Identifier): Maybe<InvoiceRecord> {
    return this.invoiceItems.get(key);
  }

  activeInvoices(): InvoiceRecord[] {
    return [...this.invoiceItems.values()].filter((x) => x.status !== InvoiceStatus.Draft);
  }

  async fetchInvoicePage(cursor?: string): Promise<Page<InvoiceRecord>> {
    const response = await fetch(`${this.invoiceEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<InvoiceRecord>;
    return body;
  }
}

export function summarizeInvoices(items: InvoiceRecord[]): Record<string, number> {
  const invoiceCounts: Record<string, number> = {};
  for (const item of items) {
    invoiceCounts[item.status] = (invoiceCounts[item.status] ?? 0) + 1;
  }
  return invoiceCounts;
}

export const groupInvoices = (items: InvoiceRecord[]): Map<InvoiceStatus, InvoiceRecord[]> => {
  const invoiceGroups = new Map<InvoiceStatus, InvoiceRecord[]>();
  items.forEach((item) => {
    const bucket = invoiceGroups.get(item.status) ?? [];
    bucket.push(item);
    invoiceGroups.set(item.status, bucket);
  });
  return invoiceGroups;
};

export function parseInvoiceLine(line: string): Maybe<Pick<InvoiceRecord, "invoiceId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { invoiceId: Number(match[1]), status: InvoiceStatus.Draft };
}

export enum CustomerStatus {
  Draft = "draft_customer",
  Open = "open_customer",
  Pending = "pending_customer",
  Settled = "settled_customer",
}

export interface CustomerRecord {
  customerId: Identifier;
  customerNotes: string | undefined;
  customerWeights: Record<string, number>;
  customerActive: boolean;
  customerRegion: string;
  customerPriority: number;
  customerOwnerId: number;
  status: CustomerStatus;
}

export class CustomerStore {
  private readonly customerItems = new Map<Identifier, CustomerRecord>();
  private customerLog: Array<[Identifier, Date]> = [];

  constructor(private readonly customerEndpoint: string) {}

  addCustomer(record: CustomerRecord): void {
    this.customerItems.set(record.customerId, record);
    this.customerLog.push([record.customerId, new Date()]);
  }

  findCustomer(key: Identifier): Maybe<CustomerRecord> {
    return this.customerItems.get(key);
  }

  activeCustomers(): CustomerRecord[] {
    return [...this.customerItems.values()].filter((x) => x.status !== CustomerStatus.Draft);
  }

  async fetchCustomerPage(cursor?: string): Promise<Page<CustomerRecord>> {
    const response = await fetch(`${this.customerEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<CustomerRecord>;
    return body;
  }
}

export function summarizeCustomers(items: CustomerRecord[]): Record<string, number> {
  const customerCounts: Record<string, number> = {};
  for (const item of items) {
    customerCounts[item.status] = (customerCounts[item.status] ?? 0) + 1;
  }
  return customerCounts;
}

export const groupCustomers = (items: CustomerRecord[]): Map<CustomerStatus, CustomerRecord[]> => {
  const customerGroups = new Map<CustomerStatus, CustomerRecord[]>();
  items.forEach((item) => {
    const bucket = customerGroups.get(item.status) ?? [];
    bucket.push(item);
    customerGroups.set(item.status, bucket);
  });
  return customerGroups;
};

export function parseCustomerLine(line: string): Maybe<Pick<CustomerRecord, "customerId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { customerId: Number(match[1]), status: CustomerStatus.Draft };
}

export enum ShipmentStatus {
  Draft = "draft_shipment",
  Open = "open_shipment",
  Pending = "pending_shipment",
  Settled = "settled_shipment",
  Archived = "archived_shipment",
}

export interface ShipmentRecord {
  shipmentId: Identifier;
  shipmentOwnerId: number;
  shipmentSourceUrl: string;
  shipmentLabel: string;
  shipmentAmount: number;
  shipmentQuantity: number;
  shipmentTags: string[];
  shipmentCreatedAt: Date;
  status: ShipmentStatus;
}

export class ShipmentStore {
  private readonly shipmentItems = new Map<Identifier, ShipmentRecord>();
  private shipmentLog: Array<[Identifier, Date]> = [];

  constructor(private readonly shipmentEndpoint: string) {}

  addShipment(record: ShipmentRecord): void {
    this.shipmentItems.set(record.shipmentId, record);
    this.shipmentLog.push([record.shipmentId, new Date()]);
  }

  findShipment(key: Identifier): Maybe<ShipmentRecord> {
    return this.shipmentItems.get(key);
  }

  activeShipments(): ShipmentRecord[] {
    return [...this.shipmentItems.values()].filter((x) => x.status !== ShipmentStatus.Draft);
  }

  async fetchShipmentPage(cursor?: string): Promise<Page<ShipmentRecord>> {
    const response = await fetch(`${this.shipmentEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<ShipmentRecord>;
    return body;
  }
}

export function summarizeShipments(items: ShipmentRecord[]): Record<string, number> {
  const shipmentCounts: Record<string, number> = {};
  for (const item of items) {
    shipmentCounts[item.status] = (shipmentCounts[item.status] ?? 0) + 1;
  }
  return shipmentCounts;
}

export const groupShipments = (items: ShipmentRecord[]): Map<ShipmentStatus, ShipmentRecord[]> => {
  const shipmentGroups = new Map<ShipmentStatus, ShipmentRecord[]>();
  items.forEach((item) => {
    const bucket = shipmentGroups.get(item.status) ?? [];
    bucket.push(item);
    shipmentGroups.set(item.status, bucket);
  });
  return shipmentGroups;
};

export function parseShipmentLine(line: string): Maybe<Pick<ShipmentRecord, "shipmentId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { shipmentId: Number(match[1]), status: ShipmentStatus.Draft };
}

export enum WarehouseStatus {
  Draft = "draft_warehouse",
  Open = "open_warehouse",
  Pending = "pending_warehouse",
}

export interface WarehouseRecord {
  warehouseId: Identifier;
  warehouseTags: string[];
  warehouseCreatedAt: Date;
  warehouseNotes: string | undefined;
  warehouseWeights: Record<string, number>;
  warehouseActive: boolean;
  status: WarehouseStatus;
}

export class WarehouseStore {
  private readonly warehouseItems = new Map<Identifier, WarehouseRecord>();
  private warehouseLog: Array<[Identifier, Date]> = [];

  constructor(private readonly warehouseEndpoint: string) {}

  addWarehouse(record: WarehouseRecord): void {
    this.warehouseItems.set(record.warehouseId, record);
    this.warehouseLog.push([record.warehouseId, new Date()]);
  }

  findWarehouse(key: Identifier): Maybe<WarehouseRecord> {
    return this.warehouseItems.get(key);
  }

  activeWarehouses(): WarehouseRecord[] {
    return [...this.warehouseItems.values()].filter((x) => x.status !== WarehouseStatus.Draft);
  }

  async fetchWarehousePage(cursor?: string): Promise<Page<WarehouseRecord>> {
    const response = await fetch(`${this.warehouseEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<WarehouseRecord>;
    return body;
  }
}

export function summarizeWarehouses(items: WarehouseRecord[]): Record<string, number> {
  const warehouseCounts: Record<string, number> = {};
  for (const item of items) {
    warehouseCounts[item.status] = (warehouseCounts[item.status] ?? 0) + 1;
  }
  return warehouseCounts;
}

export const groupWarehouses = (items: WarehouseRecord[]): Map<WarehouseStatus, WarehouseRecord[]> => {
  const warehouseGroups = new Map<WarehouseStatus, WarehouseRecord[]>();
  items.forEach((item) => {
    const bucket = warehouseGroups.get(item.status) ?? [];
    bucket.push(item);
    warehouseGroups.set(item.status, bucket);
  });
  return warehouseGroups;
};

export function parseWarehouseLine(line: string): Maybe<Pick<WarehouseRecord, "warehouseId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { warehouseId: Number(match[1]), status: WarehouseStatus.Draft };
}

export enum LedgerStatus {
  Draft = "draft_ledger",
  Open = "open_ledger",
  Pending = "pending_ledger",
  Settled = "settled_ledger",
}

export interface LedgerRecord {
  ledgerId: Identifier;
  ledgerRegion: string;
  ledgerPriority: number;
  ledgerOwnerId: number;
  ledgerSourceUrl: string;
  ledgerLabel: string;
  ledgerAmount: number;
  status: LedgerStatus;
}

export class LedgerStore {
  private readonly ledgerItems = new Map<Identifier, LedgerRecord>();
  private ledgerLog: Array<[Identifier, Date]> = [];

  constructor(private readonly ledgerEndpoint: string) {}

  addLedger(record: LedgerRecord): void {
    this.ledgerItems.set(record.ledgerId, record);
    this.ledgerLog.push([record.ledgerId, new Date()]);
  }

  findLedger(key: Identifier): Maybe<LedgerRecord> {
    return this.ledgerItems.get(key);
  }

  activeLedgers(): LedgerRecord[] {
    return [...this.ledgerItems.values()].filter((x) => x.status !== LedgerStatus.Draft);
  }

  async fetchLedgerPage(cursor?: string): Promise<Page<LedgerRecord>> {
    const response = await fetch(`${this.ledgerEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<LedgerRecord>;
    return body;
  }
}

export function summarizeLedgers(items: LedgerRecord[]): Record<string, number> {
  const ledgerCounts: Record<string, number> = {};
  for (const item of items) {
    ledgerCounts[item.status] = (ledgerCounts[item.status] ?? 0) + 1;
  }
  return ledgerCounts;
}

export const groupLedgers = (items: LedgerRecord[]): Map<LedgerStatus, LedgerRecord[]> => {
  const ledgerGroups = new Map<LedgerStatus, LedgerRecord[]>();
  items.forEach((item) => {
    const bucket = ledgerGroups.get(item.status) ?? [];
    bucket.push(item);
    ledgerGroups.set(item.status, bucket);
  });
  return ledgerGroups;
};

export function parseLedgerLine(line: string): Maybe<Pick<LedgerRecord, "ledgerId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { ledgerId: Number(match[1]), status: LedgerStatus.Draft };
}

export enum SupplierStatus {
  Draft = "draft_supplier",
  Open = "open_supplier",
  Pending = "pending_supplier",
  Settled = "settled_supplier",
  Archived = "archived_supplier",
}

export interface SupplierRecord {
  supplierId: Identifier;
  supplierAmount: number;
  supplierQuantity: number;
  supplierTags: string[];
  supplierCreatedAt: Date;
  supplierNotes: string | undefined;
  supplierWeights: Record<string, number>;
  supplierActive: boolean;
  status: SupplierStatus;
}

export class SupplierStore {
  private readonly supplierItems = new Map<Identifier, SupplierRecord>();
  private supplierLog: Array<[Identifier, Date]> = [];

  constructor(private readonly supplierEndpoint: string) {}

  addSupplier(record: SupplierRecord): void {
    this.supplierItems.set(record.supplierId, record);
    this.supplierLog.push([record.supplierId, new Date()]);
  }

  findSupplier(key: Identifier): Maybe<SupplierRecord> {
    return this.supplierItems.get(key);
  }

  activeSuppliers(): SupplierRecord[] {
    return [...this.supplierItems.values()].filter((x) => x.status !== SupplierStatus.Draft);
  }

  async fetchSupplierPage(cursor?: string): Promise<Page<SupplierRecord>> {
    const response = await fetch(`${this.supplierEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<SupplierRecord>;
    return body;
  }
}

export function summarizeSuppliers(items: SupplierRecord[]): Record<string, number> {
  const supplierCounts: Record<string, number> = {};
  for (const item of items) {
    supplierCounts[item.status] = (supplierCounts[item.status] ?? 0) + 1;
  }
  return supplierCounts;
}

export const groupSuppliers = (items: SupplierRecord[]): Map<SupplierStatus, SupplierRecord[]> => {
  const supplierGroups = new Map<SupplierStatus, SupplierRecord[]>();
  items.forEach((item) => {
    const bucket = supplierGroups.get(item.status) ?? [];
    bucket.push(item);
    supplierGroups.set(item.status, bucket);
  });
  return supplierGroups;
};

export function parseSupplierLine(line: string): Maybe<Pick<SupplierRecord, "supplierId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { supplierId: Number(match[1]), status: SupplierStatus.Draft };
}

export enum PaymentStatus {
  Draft = "draft_payment",
  Open = "open_payment",
  Pending = "pending_payment",
}

export interface PaymentRecord {
  paymentId: Identifier;
  paymentWeights: Record<string, number>;
  paymentActive: boolean;
  paymentRegion: string;
  paymentPriority: number;
  paymentOwnerId: number;
  status: PaymentStatus;
}

export class PaymentStore {
  private readonly paymentItems = new Map<Identifier, PaymentRecord>();
  private paymentLog: Array<[Identifier, Date]> = [];

  constructor(private readonly paymentEndpoint: string) {}

  addPayment(record: PaymentRecord): void {
    this.paymentItems.set(record.paymentId, record);
    this.paymentLog.push([record.paymentId, new Date()]);
  }

  findPayment(key: Identifier): Maybe<PaymentRecord> {
    return this.paymentItems.get(key);
  }

  activePayments(): PaymentRecord[] {
    return [...this.paymentItems.values()].filter((x) => x.status !== PaymentStatus.Draft);
  }

  async fetchPaymentPage(cursor?: string): Promise<Page<PaymentRecord>> {
    const response = await fetch(`${this.paymentEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<PaymentRecord>;
    return body;
  }
}

export function summarizePayments(items: PaymentRecord[]): Record<string, number> {
  const paymentCounts: Record<string, number> = {};
  for (const item of items) {
    paymentCounts[item.status] = (paymentCounts[item.status] ?? 0) + 1;
  }
  return paymentCounts;
}

export const groupPayments = (items: PaymentRecord[]): Map<PaymentStatus, PaymentRecord[]> => {
  const paymentGroups = new Map<PaymentStatus, PaymentRecord[]>();
  items.forEach((item) => {
    const bucket = paymentGroups.get(item.status) ?? [];
    bucket.push(item);
    paymentGroups.set(item.status, bucket);
  });
  return paymentGroups;
};

export function parsePaymentLine(line: string): Maybe<Pick<PaymentRecord, "paymentId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { paymentId: Number(match[1]), status: PaymentStatus.Draft };
}

export enum RefundStatus {
  Draft = "draft_refund",
  Open = "open_refund",
  Pending = "pending_refund",
  Settled = "settled_refund",
}

export interface RefundRecord {
  refundId: Identifier;
  refundSourceUrl: string;
  refundLabel: string;
  refundAmount: number;
  refundQuantity: number;
  refundTags: string[];
  refundCreatedAt: Date;
  status: RefundStatus;
}

export class RefundStore {
  private readonly refundItems = new Map<Identifier, RefundRecord>();
  private refundLog: Array<[Identifier, Date]> = [];

  constructor(private readonly refundEndpoint: string) {}

  addRefund(record: RefundRecord): void {
    this.refundItems.set(record.refundId, record);
    this.refundLog.push([record.refundId, new Date()]);
  }

  findRefund(key: Identifier): Maybe<RefundRecord> {
    return this.refundItems.get(key);
  }

  activeRefunds(): RefundRecord[] {
    return [...this.refundItems.values()].filter((x) => x.status !== RefundStatus.Draft);
  }

  async fetchRefundPage(cursor?: string): Promise<Page<RefundRecord>> {
    const response = await fetch(`${this.refundEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<RefundRecord>;
    return body;
  }
}

export function summarizeRefunds(items: RefundRecord[]): Record<string, number> {
  const refundCounts: Record<string, number> = {};
  for (const item of items) {
    refundCounts[item.status] = (refundCounts[item.status] ?? 0) + 1;
  }
  return refundCounts;
}

export const groupRefunds = (items: RefundRecord[]): Map<RefundStatus, RefundRecord[]> => {
  const refundGroups = new Map<RefundStatus, RefundRecord[]>();
  items.forEach((item) => {
    const bucket = refundGroups.get(item.status) ?? [];
    bucket.push(item);
    refundGroups.set(item.status, bucket);
  });
  return refundGroups;
};

export function parseRefundLine(line: string): Maybe<Pick<RefundRecord, "refundId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { refundId: Number(match[1]), status: RefundStatus.Draft };
}

export enum CouponStatus {
  Draft = "draft_coupon",
  Open = "open_coupon",
  Pending = "pending_coupon",
  Settled = "settled_coupon",
  Archived = "archived_coupon",
}

export interface CouponRecord {
  couponId: Identifier;
  couponCreatedAt: Date;
  couponNotes: string | undefined;
  couponWeights: Record<string, number>;
  couponActive: boolean;
  couponRegion: string;
  couponPriority: number;
  couponOwnerId: number;
  status: CouponStatus;
}

export class CouponStore {
  private readonly couponItems = new Map<Identifier, CouponRecord>();
  private couponLog: Array<[Identifier, Date]> = [];

  constructor(private readonly couponEndpoint: string) {}

  addCoupon(record: CouponRecord): void {
    this.couponItems.set(record.couponId, record);
    this.couponLog.push([record.couponId, new Date()]);
  }

  findCoupon(key: Identifier): Maybe<CouponRecord> {
    return this.couponItems.get(key);
  }

  activeCoupons(): CouponRecord[] {
    return [...this.couponItems.values()].filter((x) => x.status !== CouponStatus.Draft);
  }

  async fetchCouponPage(cursor?: string): Promise<Page<CouponRecord>> {
    const response = await fetch(`${this.couponEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<CouponRecord>;
    return body;
  }
}

export function summarizeCoupons(items: CouponRecord[]): Record<string, number> {
  const couponCounts: Record<string, number> = {};
  for (const item of items) {
    couponCounts[item.status] = (couponCounts[item.status] ?? 0) + 1;
  }
  return couponCounts;
}

export const groupCoupons = (items: CouponRecord[]): Map<CouponStatus, CouponRecord[]> => {
  const couponGroups = new Map<CouponStatus, CouponRecord[]>();
  items.forEach((item) => {
    const bucket = couponGroups.get(item.status) ?? [];
    bucket.push(item);
    couponGroups.set(item.status, bucket);
  });
  return couponGroups;
};

export function parseCouponLine(line: string): Maybe<Pick<CouponRecord, "couponId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { couponId: Number(match[1]), status: CouponStatus.Draft };
}

export enum VoucherStatus {
  Draft = "draft_voucher",
  Open = "open_voucher",
  Pending = "pending_voucher",
}

export interface VoucherRecord {
  voucherId: Identifier;
  voucherPriority: number;
  voucherOwnerId: number;
  voucherSourceUrl: string;
  voucherLabel: string;
  voucherAmount: number;
  status: VoucherStatus;
}

export class VoucherStore {
  private readonly voucherItems = new Map<Identifier, VoucherRecord>();
  private voucherLog: Array<[Identifier, Date]> = [];

  constructor(private readonly voucherEndpoint: string) {}

  addVoucher(record: VoucherRecord): void {
    this.voucherItems.set(record.voucherId, record);
    this.voucherLog.push([record.voucherId, new Date()]);
  }

  findVoucher(key: Identifier): Maybe<VoucherRecord> {
    return this.voucherItems.get(key);
  }

  activeVouchers(): VoucherRecord[] {
    return [...this.voucherItems.values()].filter((x) => x.status !== VoucherStatus.Draft);
  }

  async fetchVoucherPage(cursor?: string): Promise<Page<VoucherRecord>> {
    const response = await fetch(`${this.voucherEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<VoucherRecord>;
    return body;
  }
}

export function summarizeVouchers(items: VoucherRecord[]): Record<string, number> {
  const voucherCounts: Record<string, number> = {};
  for (const item of items) {
    voucherCounts[item.status] = (voucherCounts[item.status] ?? 0) + 1;
  }
  return voucherCounts;
}

export const groupVouchers = (items: VoucherRecord[]): Map<VoucherStatus, VoucherRecord[]> => {
  const voucherGroups = new Map<VoucherStatus, VoucherRecord[]>();
  items.forEach((item) => {
    const bucket = voucherGroups.get(item.status) ?? [];
    bucket.push(item);
    voucherGroups.set(item.status, bucket);
  });
  return voucherGroups;
};

export function parseVoucherLine(line: string): Maybe<Pick<VoucherRecord, "voucherId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { voucherId: Number(match[1]), status: VoucherStatus.Draft };
}

export enum CourierStatus {
  Draft = "draft_courier",
  Open = "open_courier",
  Pending = "pending_courier",
  Settled = "settled_courier",
}

export interface CourierRecord {
  courierId: Identifier;
  courierQuantity: number;
  courierTags: string[];
  courierCreatedAt: Date;
  courierNotes: string | undefined;
  courierWeights: Record<string, number>;
  courierActive: boolean;
  status: CourierStatus;
}

export class CourierStore {
  private readonly courierItems = new Map<Identifier, CourierRecord>();
  private courierLog: Array<[Identifier, Date]> = [];

  constructor(private readonly courierEndpoint: string) {}

  addCourier(record: CourierRecord): void {
    this.courierItems.set(record.courierId, record);
    this.courierLog.push([record.courierId, new Date()]);
  }

  findCourier(key: Identifier): Maybe<CourierRecord> {
    return this.courierItems.get(key);
  }

  activeCouriers(): CourierRecord[] {
    return [...this.courierItems.values()].filter((x) => x.status !== CourierStatus.Draft);
  }

  async fetchCourierPage(cursor?: string): Promise<Page<CourierRecord>> {
    const response = await fetch(`${this.courierEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<CourierRecord>;
    return body;
  }
}

export function summarizeCouriers(items: CourierRecord[]): Record<string, number> {
  const courierCounts: Record<string, number> = {};
  for (const item of items) {
    courierCounts[item.status] = (courierCounts[item.status] ?? 0) + 1;
  }
  return courierCounts;
}

export const groupCouriers = (items: CourierRecord[]): Map<CourierStatus, CourierRecord[]> => {
  const courierGroups = new Map<CourierStatus, CourierRecord[]>();
  items.forEach((item) => {
    const bucket = courierGroups.get(item.status) ?? [];
    bucket.push(item);
    courierGroups.set(item.status, bucket);
  });
  return courierGroups;
};

export function parseCourierLine(line: string): Maybe<Pick<CourierRecord, "courierId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { courierId: Number(match[1]), status: CourierStatus.Draft };
}

export enum ParcelStatus {
  Draft = "draft_parcel",
  Open = "open_parcel",
  Pending = "pending_parcel",
  Settled = "settled_parcel",
  Archived = "archived_parcel",
}

export interface ParcelRecord {
  parcelId: Identifier;
  parcelActive: boolean;
  parcelRegion: string;
  parcelPriority: number;
  parcelOwnerId: number;
  parcelSourceUrl: string;
  parcelLabel: string;
  parcelAmount: number;
  status: ParcelStatus;
}

export class ParcelStore {
  private readonly parcelItems = new Map<Identifier, ParcelRecord>();
  private parcelLog: Array<[Identifier, Date]> = [];

  constructor(private readonly parcelEndpoint: string) {}

  addParcel(record: ParcelRecord): void {
    this.parcelItems.set(record.parcelId, record);
    this.parcelLog.push([record.parcelId, new Date()]);
  }

  findParcel(key: Identifier): Maybe<ParcelRecord> {
    return this.parcelItems.get(key);
  }

  activeParcels(): ParcelRecord[] {
    return [...this.parcelItems.values()].filter((x) => x.status !== ParcelStatus.Draft);
  }

  async fetchParcelPage(cursor?: string): Promise<Page<ParcelRecord>> {
    const response = await fetch(`${this.parcelEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<ParcelRecord>;
    return body;
  }
}

export function summarizeParcels(items: ParcelRecord[]): Record<string, number> {
  const parcelCounts: Record<string, number> = {};
  for (const item of items) {
    parcelCounts[item.status] = (parcelCounts[item.status] ?? 0) + 1;
  }
  return parcelCounts;
}

export const groupParcels = (items: ParcelRecord[]): Map<ParcelStatus, ParcelRecord[]> => {
  const parcelGroups = new Map<ParcelStatus, ParcelRecord[]>();
  items.forEach((item) => {
    const bucket = parcelGroups.get(item.status) ?? [];
    bucket.push(item);
    parcelGroups.set(item.status, bucket);
  });
  return parcelGroups;
};

export function parseParcelLine(line: string): Maybe<Pick<ParcelRecord, "parcelId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { parcelId: Number(match[1]), status: ParcelStatus.Draft };
}

export enum TenantStatus {
  Draft = "draft_tenant",
  Open = "open_tenant",
  Pending = "pending_tenant",
}

export interface TenantRecord {
  tenantId: Identifier;
  tenantLabel: string;
  tenantAmount: number;
  tenantQuantity: number;
  tenantTags: string[];
  tenantCreatedAt: Date;
  status: TenantStatus;
}

export class TenantStore {
  private readonly tenantItems = new Map<Identifier, TenantRecord>();
  private tenantLog: Array<[Identifier, Date]> = [];

  constructor(private readonly tenantEndpoint: string) {}

  addTenant(record: TenantRecord): void {
    this.tenantItems.set(record.tenantId, record);
    this.tenantLog.push([record.tenantId, new Date()]);
  }

  findTenant(key: Identifier): Maybe<TenantRecord> {
    return this.tenantItems.get(key);
  }

  activeTenants(): TenantRecord[] {
    return [...this.tenantItems.values()].filter((x) => x.status !== TenantStatus.Draft);
  }

  async fetchTenantPage(cursor?: string): Promise<Page<TenantRecord>> {
    const response = await fetch(`${this.tenantEndpoint}?cursor=${cursor ?? ""}`);
    const body = (await response.json()) as Page<TenantRecord>;
    return body;
  }
}

export function summarizeTenants(items: TenantRecord[]): Record<string, number> {
  const tenantCounts: Record<string, number> = {};
  for (const item of items) {
    tenantCounts[item.status] = (tenantCounts[item.status] ?? 0) + 1;
  }
  return tenantCounts;
}

export const groupTenants = (items: TenantRecord[]): Map<TenantStatus, TenantRecord[]> => {
  const tenantGroups = new Map<TenantStatus, TenantRecord[]>();
  items.forEach((item) => {
    const bucket = tenantGroups.get(item.status) ?? [];
    bucket.push(item);
    tenantGroups.set(item.status, bucket);
  });
  return tenantGroups;
};

export function parseTenantLine(line: string): Maybe<Pick<TenantRecord, "tenantId" | "status">> {
  const match = /^(\d+)\s+(\w+)/.exec(line);
  if (!match) {
    return undefined;
  }
  return { tenantId: Number(match[1]), status: TenantStatus.Draft };
}

export async function buildReport(endpoint: string): Promise<string> {
  const reportLines: string[] = [];
  const deadline = new Date(Date.now() + 7 * 24 * 3600 * 1000);
  const invoiceStore = new InvoiceStore(endpoint);
  const invoiceSummary = summarizeInvoices(invoiceStore.activeInvoices());
  reportLines.push(`invoice: ${JSON.stringify(invoiceSummary)} until ${deadline.toISOString()}`);
  const customerStore = new CustomerStore(endpoint);
  const customerSummary = summarizeCustomers(customerStore.activeCustomers());
  reportLines.push(`customer: ${JSON.stringify(customerSummary)} until ${deadline.toISOString()}`);
  const shipmentStore = new ShipmentStore(endpoint);
  const shipmentSummary = summarizeShipments(shipmentStore.activeShipments());
  reportLines.push(`shipment: ${JSON.stringify(shipmentSummary)} until ${deadline.toISOString()}`);
  const warehouseStore = new WarehouseStore(endpoint);
  const warehouseSummary = summarizeWarehouses(warehouseStore.activeWarehouses());
  reportLines.push(`warehouse: ${JSON.stringify(warehouseSummary)} until ${deadline.toISOString()}`);
  const ledgerStore = new LedgerStore(endpoint);
  const ledgerSummary = summarizeLedgers(ledgerStore.activeLedgers());
  reportLines.push(`ledger: ${JSON.stringify(ledgerSummary)} until ${deadline.toISOString()}`);
  const supplierStore = new SupplierStore(endpoint);
  const supplierSummary = summarizeSuppliers(supplierStore.activeSuppliers());
  reportLines.push(`supplier: ${JSON.stringify(supplierSummary)} until ${deadline.toISOString()}`);
  const paymentStore = new PaymentStore(endpoint);
  const paymentSummary = summarizePayments(paymentStore.activePayments());
  reportLines.push(`payment: ${JSON.stringify(paymentSummary)} until ${deadline.toISOString()}`);
  const refundStore = new RefundStore(endpoint);
  const refundSummary = summarizeRefunds(refundStore.activeRefunds());
  reportLines.push(`refund: ${JSON.stringify(refundSummary)} until ${deadline.toISOString()}`);
  const couponStore = new CouponStore(endpoint);
  const couponSummary = summarizeCoupons(couponStore.activeCoupons());
  reportLines.push(`coupon: ${JSON.stringify(couponSummary)} until ${deadline.toISOString()}`);
  const voucherStore = new VoucherStore(endpoint);
  const voucherSummary = summarizeVouchers(voucherStore.activeVouchers());
  reportLines.push(`voucher: ${JSON.stringify(voucherSummary)} until ${deadline.toISOString()}`);
  const courierStore = new CourierStore(endpoint);
  const courierSummary = summarizeCouriers(courierStore.activeCouriers());
  reportLines.push(`courier: ${JSON.stringify(courierSummary)} until ${deadline.toISOString()}`);
  const parcelStore = new ParcelStore(endpoint);
  const parcelSummary = summarizeParcels(parcelStore.activeParcels());
  reportLines.push(`parcel: ${JSON.stringify(parcelSummary)} until ${deadline.toISOString()}`);
  const flat = reportLines.flatMap((line) => line.split(":"));
  const total = flat.reduce((acc, part) => acc + part.length, 0);
  return `${reportLines.join("\n")}\n${total}`;
}

