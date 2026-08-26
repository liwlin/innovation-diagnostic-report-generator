"""restrict the runtime role and make audit rows append-only

Revision ID: 0002
Revises: 0001
Create Date: 2026-08-26
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

BUSINESS_TABLES = (
    "users",
    "sessions",
    "batches",
    "students",
    "evaluations",
    "evaluation_versions",
    "generation_records",
    "emergency_imports",
)


def upgrade() -> None:
    if op.get_bind().dialect.name != "postgresql":
        return
    op.execute("REVOKE CREATE ON SCHEMA public FROM makerseed_app")
    op.execute("GRANT USAGE ON SCHEMA public TO makerseed_app")
    for table in BUSINESS_TABLES:
        op.execute(f'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "{table}" TO makerseed_app')
    op.execute("GRANT SELECT, INSERT ON TABLE audit_events TO makerseed_app")
    op.execute("REVOKE UPDATE, DELETE, TRUNCATE ON TABLE audit_events FROM makerseed_app")
    op.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO makerseed_app")


def downgrade() -> None:
    if op.get_bind().dialect.name != "postgresql":
        return
    for table in BUSINESS_TABLES:
        op.execute(f'REVOKE ALL PRIVILEGES ON TABLE "{table}" FROM makerseed_app')
    op.execute("REVOKE ALL PRIVILEGES ON TABLE audit_events FROM makerseed_app")
    op.execute("REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM makerseed_app")
    op.execute("REVOKE USAGE ON SCHEMA public FROM makerseed_app")
