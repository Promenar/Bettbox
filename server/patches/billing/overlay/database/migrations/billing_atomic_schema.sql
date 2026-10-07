CREATE TABLE v2_billing_mutex(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL DEFAULT 0);
INSERT INTO v2_billing_mutex(id,revision) VALUES(1,0);
CREATE TABLE v2_payment_attempt(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 order_id INTEGER NOT NULL REFERENCES v2_order(id),
 payment_id INTEGER NOT NULL REFERENCES v2_payment(id),
 external_no TEXT NOT NULL UNIQUE CHECK(length(external_no)=32),
 identity_mode TEXT NOT NULL CHECK(identity_mode IN ('merchant','vendor')),
 identity_key TEXT NOT NULL,
 secret_ref TEXT NOT NULL,
 provider_scope TEXT NOT NULL,
 merchant_id INTEGER NOT NULL CHECK(merchant_id>0),
 store_id INTEGER NOT NULL CHECK(store_id>0),
 expected_cents INTEGER NOT NULL CHECK(typeof(expected_cents)='integer' AND expected_cents>0 AND expected_cents<=1000000000),
 provider_no TEXT NULL,
 status INTEGER NOT NULL DEFAULT 0 CHECK(status IN (0,1,2)),
 created_at INTEGER NOT NULL,
 UNIQUE(provider_scope,provider_no)
);
CREATE INDEX billing_attempt_order ON v2_payment_attempt(order_id,status);
CREATE UNIQUE INDEX billing_attempt_one_pending ON v2_payment_attempt(order_id) WHERE status=0;
CREATE TRIGGER billing_attempt_immutable BEFORE UPDATE ON v2_payment_attempt
 WHEN NEW.order_id IS NOT OLD.order_id OR NEW.payment_id IS NOT OLD.payment_id
 OR NEW.external_no IS NOT OLD.external_no OR NEW.identity_mode IS NOT OLD.identity_mode
 OR NEW.identity_key IS NOT OLD.identity_key OR NEW.provider_scope IS NOT OLD.provider_scope
 OR NEW.secret_ref IS NOT OLD.secret_ref
 OR NEW.merchant_id IS NOT OLD.merchant_id OR NEW.store_id IS NOT OLD.store_id
 OR NEW.expected_cents IS NOT OLD.expected_cents OR NEW.created_at IS NOT OLD.created_at
 OR (OLD.provider_no IS NOT NULL AND NEW.provider_no IS NOT OLD.provider_no)
 OR (OLD.status IN (1,2) AND NEW.status IS NOT OLD.status)
 BEGIN SELECT RAISE(ABORT,'immutable payment attempt'); END;
CREATE TRIGGER billing_attempt_no_delete BEFORE DELETE ON v2_payment_attempt
 BEGIN SELECT RAISE(ABORT,'payment evidence cannot be deleted'); END;
CREATE TABLE v2_billing_review(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 order_id INTEGER NOT NULL REFERENCES v2_order(id),
 category TEXT NOT NULL,
 reason TEXT NOT NULL,
 created_at INTEGER NOT NULL,
 UNIQUE(order_id,category)
);
CREATE TABLE v2_billing_outbox(
 event_id TEXT PRIMARY KEY,
 order_id INTEGER NOT NULL REFERENCES v2_order(id),
 event_type TEXT NOT NULL CHECK(event_type='payment.notify.success'),
 created_at INTEGER NOT NULL,
 attempts INTEGER NOT NULL DEFAULT 0,
 lease_until INTEGER NOT NULL DEFAULT 0,
 lease_token TEXT NULL,
 delivered_at INTEGER NULL,
 UNIQUE(order_id,event_type)
);
ALTER TABLE v2_commission_log ADD COLUMN order_id INTEGER NULL REFERENCES v2_order(id);
ALTER TABLE v2_commission_log ADD COLUMN level INTEGER NULL CHECK(level IS NULL OR level BETWEEN 0 AND 2);
CREATE UNIQUE INDEX billing_commission_order_level ON v2_commission_log(order_id,level);
