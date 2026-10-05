// nfs.ts — module-manager's view of storage:nfs (ADR-029 v0.9). The share model is
// shared with storage-manager in lib/ts/src/nfs-shares.ts; validate checks each
// consumer's mounts against config/shares.json. The shares file itself is validated
// by `storage-manager validate`, its owner.
export {
  NFS_COORDINATE,
  checkMounts,
  isPublicIpv4,
  parseShareRef,
  shareAlias,
} from "../../../lib/ts/src/nfs-shares";
