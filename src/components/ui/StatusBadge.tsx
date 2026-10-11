import {
  CUSTOMER_STATUS_LABEL,
  CUSTOMER_STATUS_TONE,
  SYNC_STATE_LABEL,
  SYNC_STATE_TONE,
  TONE_ICON,
  type CustomerStatus,
  type SyncState,
  type Tone,
} from "./labels";

function Badge({ tone, label }: { tone: Tone; label: string }) {
  return (
    <span className={`ui-badge ui-badge--${tone}`}>
      <span aria-hidden="true">{TONE_ICON[tone]}</span>
      {label}
    </span>
  );
}

/** Status yang dilihat pelanggan (bukan status internal WO). */
export function StatusBadge({ status }: { status: CustomerStatus }) {
  return <Badge tone={CUSTOMER_STATUS_TONE[status]} label={CUSTOMER_STATUS_LABEL[status]} />;
}

/** Keadaan sinkron per item (FR-060). */
export function SyncIndicator({ state }: { state: SyncState }) {
  return <Badge tone={SYNC_STATE_TONE[state]} label={SYNC_STATE_LABEL[state]} />;
}
