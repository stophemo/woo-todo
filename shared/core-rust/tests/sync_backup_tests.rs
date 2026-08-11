use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

use serde::Deserialize;
use serde_json::{Value, json};
use woo_todo_core::*;

fn fixture(name: &str) -> Vec<u8> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../fixtures")
        .join(name);
    fs::read(path).unwrap()
}

#[test]
fn base64url_is_canonical_and_aes_vector_matches_other_clients() {
    let root: Value = serde_json::from_slice(&fixture("crypto-vectors.json")).unwrap();
    let vector = &root["aes256Gcm"]["vectors"][0];
    let key = base64url_decode(vector["key"].as_str().unwrap()).unwrap();
    let nonce = base64url_decode(vector["nonce"].as_str().unwrap()).unwrap();
    let aad = base64url_decode(vector["aad"].as_str().unwrap()).unwrap();
    let plaintext = base64url_decode(vector["plaintext"].as_str().unwrap()).unwrap();

    let envelope = aes256_gcm_seal(&plaintext, &key, Some(&nonce), &aad).unwrap();
    assert_eq!(envelope.nonce, vector["nonce"]);
    assert_eq!(envelope.ciphertext, vector["ciphertext"]);
    assert_eq!(aes256_gcm_open(&envelope, &key, &aad).unwrap(), plaintext);

    assert!(base64url_decode("AA==").is_err());
    assert!(base64url_decode("a").is_err());
    assert!(base64url_decode("+/8").is_err());
}

#[test]
fn shared_task_and_sync_fixtures_decode_with_strict_fields() {
    let entities: Vec<WireEntity> = serde_json::from_slice(&fixture("task-payloads.json")).unwrap();
    assert_eq!(entities.len(), 4);
    assert!(matches!(entities[0], WireEntity::Task(_)));
    assert!(matches!(entities[2], WireEntity::Tombstone(_)));
    assert!(matches!(entities[3], WireEntity::DisplayConfiguration(_)));

    let request = decode_sync_request(&fixture("sync-request.json")).unwrap();
    assert_eq!(request.cursor, 41);
    assert_eq!(request.push.len(), 2);

    let mut unknown: Value = serde_json::from_slice(&fixture("sync-request.json")).unwrap();
    unknown["futureField"] = json!(true);
    assert!(decode_sync_request(&serde_json::to_vec(&unknown).unwrap()).is_err());

    let mut missing: Value = serde_json::from_slice(&fixture("task-payloads.json")).unwrap();
    missing[0].as_object_mut().unwrap().remove("settledAt");
    assert!(serde_json::from_value::<Vec<WireEntity>>(missing).is_err());
}

#[test]
fn operation_codec_binds_every_aad_field() {
    let entity: WireEntity = serde_json::from_value(
        serde_json::from_slice::<Value>(&fixture("task-payloads.json")).unwrap()[0].clone(),
    )
    .unwrap();
    let configuration = SyncConfiguration::new("vault-demo", "device-demo-001", &[7; 32]).unwrap();
    let envelope = OperationCodec::seal(
        &entity,
        &configuration,
        "op-demo-001",
        "550e8400-e29b-41d4-a716-446655440000",
        OperationKind::Upsert,
        42,
        Some(&[9; 12]),
    )
    .unwrap();
    let operation = SyncPushOperation {
        op_id: "op-demo-001".to_owned(),
        entity_id: "550e8400-e29b-41d4-a716-446655440000".to_owned(),
        kind: OperationKind::Upsert,
        lamport: 42,
        ciphertext: envelope.ciphertext.clone(),
        nonce: envelope.nonce.clone(),
    };
    assert_eq!(
        OperationCodec::open_push(&operation, &configuration).unwrap(),
        entity
    );

    let mut tampered = operation;
    tampered.lamport += 1;
    assert!(OperationCodec::open_push(&tampered, &configuration).is_err());
}

#[test]
fn pairing_golden_vector_matches_x25519_hkdf_code_and_envelope() {
    let root: Value = serde_json::from_slice(&fixture("crypto-vectors.json")).unwrap();
    let vector = &root["pairing"];
    let private: [u8; 32] = base64url_decode(vector["initiatorPrivateKey"].as_str().unwrap())
        .unwrap()
        .try_into()
        .unwrap();
    let claim_private: [u8; 32] = base64url_decode(vector["claimPrivateKey"].as_str().unwrap())
        .unwrap()
        .try_into()
        .unwrap();
    let initiator = PairingKeyPair::from_private_key(private).unwrap();
    let claimant = PairingKeyPair::from_private_key(claim_private).unwrap();
    assert_eq!(
        initiator.public_key_base64url(),
        vector["initiatorPublicKey"]
    );
    assert_eq!(claimant.public_key_base64url(), vector["claimPublicKey"]);
    assert_eq!(
        base64url_encode(&initiator.shared_secret(claimant.public_key()).unwrap()),
        vector["sharedSecret"]
    );

    let pairing_id = vector["pairingId"].as_str().unwrap();
    let pairing_secret = base64url_decode(vector["pairingSecret"].as_str().unwrap()).unwrap();
    let session_key = initiator
        .session_key(claimant.public_key(), pairing_id, &pairing_secret)
        .unwrap();
    assert_eq!(base64url_encode(&session_key), vector["sessionKey"]);
    assert_eq!(
        String::from_utf8(pairing_hkdf_info(pairing_id)).unwrap(),
        vector["hkdfInfoUtf8"]
    );
    assert_eq!(
        String::from_utf8(
            pairing_verification_input(initiator.public_key(), claimant.public_key()).unwrap()
        )
        .unwrap(),
        vector["verificationInputUtf8"]
    );
    assert_eq!(
        pairing_verification_code(&session_key, initiator.public_key(), claimant.public_key())
            .unwrap(),
        vector["verificationCode"]
    );

    let nonce = base64url_decode(vector["envelopeNonce"].as_str().unwrap()).unwrap();
    let vault_key = base64url_decode(vector["vaultKey"].as_str().unwrap()).unwrap();
    let claimed_device_id = vector["claimedDeviceId"].as_str().unwrap();
    let envelope = seal_pairing_vault_key(
        &vault_key,
        &session_key,
        pairing_id,
        claimed_device_id,
        Some(&nonce),
    )
    .unwrap();
    assert_eq!(envelope.ciphertext, vector["vaultKeyCiphertext"]);
    assert_eq!(
        open_pairing_vault_key(&envelope, &session_key, pairing_id, claimed_device_id)
            .unwrap()
            .as_slice(),
        vault_key
    );
    assert!(open_pairing_vault_key(&envelope, &session_key, pairing_id, "other").is_err());
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BackupVector {
    password: String,
    password_normalized: String,
    created_at: i64,
    kdf: BackupKdfParameters,
    cipher: BackupCipherPayload,
    aad_utf8: String,
    derived_key: String,
    plaintext_utf8: String,
}

#[test]
fn backup_golden_vector_opens_and_reseals_byte_for_byte() {
    let vector: BackupVector = serde_json::from_slice(&fixture("backup-vectors.json")).unwrap();
    assert_eq!(
        normalize_backup_passphrase(&vector.password).unwrap(),
        vector.password_normalized
    );
    let salt = base64url_decode(&vector.kdf.salt).unwrap();
    assert_eq!(
        base64url_encode(
            &derive_backup_key(&vector.password, &salt, vector.kdf.iterations).unwrap()
        ),
        vector.derived_key
    );
    assert_eq!(
        backup_aad_canonical(vector.created_at, &vector.kdf),
        vector.aad_utf8
    );

    let file = EncryptedBackupFile {
        format: BACKUP_FORMAT.to_owned(),
        version: BACKUP_PROTOCOL_VERSION,
        created_at: vector.created_at,
        kdf: vector.kdf.clone(),
        cipher: vector.cipher.clone(),
    };
    let snapshot = open_backup(&serde_json::to_vec(&file).unwrap(), &vector.password).unwrap();
    let expected: BackupSnapshot = serde_json::from_str(&vector.plaintext_utf8).unwrap();
    assert_eq!(snapshot, expected);

    let nonce = base64url_decode(&vector.cipher.nonce).unwrap();
    let sealed = seal_backup(
        &snapshot,
        &vector.password,
        BackupSealOptions {
            iterations: vector.kdf.iterations,
            salt: Some(salt.try_into().unwrap()),
            nonce: Some(nonce.try_into().unwrap()),
        },
    )
    .unwrap();
    let resealed: EncryptedBackupFile = serde_json::from_slice(&sealed).unwrap();
    assert_eq!(resealed, file);
    assert!(open_backup(&sealed, "这是另一个足够长的错误口令").is_err());
}

#[test]
fn backup_rejects_duplicate_entities_and_unknown_outer_fields() {
    let task = match serde_json::from_slice::<Vec<WireEntity>>(&fixture("task-payloads.json"))
        .unwrap()
        .remove(0)
    {
        WireEntity::Task(task) => task,
        _ => unreachable!(),
    };
    let snapshot = BackupSnapshot {
        exported_at: 1,
        protocol_version: 1,
        sync_credentials: None,
        tasks: vec![task.clone(), task],
        tombstones: Vec::new(),
    };
    assert!(snapshot.validate().is_err());

    let vector: Value = serde_json::from_slice(&fixture("backup-vectors.json")).unwrap();
    let mut file = json!({
        "format": BACKUP_FORMAT,
        "version": 1,
        "createdAt": vector["createdAt"],
        "kdf": vector["kdf"],
        "cipher": vector["cipher"],
        "unexpected": true
    });
    assert!(
        open_backup(
            &serde_json::to_vec(&file).unwrap(),
            vector["password"].as_str().unwrap()
        )
        .is_err()
    );
    file.as_object_mut().unwrap().remove("unexpected");
}

fn open_repository() -> (tempfile::TempDir, TaskRepository) {
    let directory = tempfile::tempdir().unwrap();
    let repository = TaskRepository::open(directory.path().join("tasks.sqlite")).unwrap();
    (directory, repository)
}

fn sync_configuration(vault: &str, device: &str, byte: u8) -> SyncConfiguration {
    SyncConfiguration::new(vault, device, &[byte; 32]).unwrap()
}

fn create_task(repository: &mut TaskRepository, title: &str, now: i64) -> String {
    repository
        .create(
            title,
            TimeType::Day,
            today_shanghai(),
            QuestLine::Main,
            false,
            None,
            None,
            now,
        )
        .unwrap()
}

#[test]
fn local_mutations_enqueue_atomically_and_deferred_changes_recover_once() {
    let (_directory, mut repository) = open_repository();
    let id = create_task(&mut repository, "绑定前任务", 100);
    assert!(repository.pending_operations(100).unwrap().is_empty());

    let configuration = sync_configuration("vault-a", "device-a", 3);
    repository.configure_sync(configuration.clone()).unwrap();
    let baseline = repository.pending_operations(100).unwrap();
    assert_eq!(baseline.len(), 1);
    assert_eq!(baseline[0].kind, OperationKind::Upsert);
    repository
        .acknowledge_operations(
            &baseline
                .iter()
                .map(|item| item.op_id.clone())
                .collect::<Vec<_>>(),
        )
        .unwrap();

    repository.complete(&id, 200).unwrap();
    let complete = repository.pending_operations(100).unwrap();
    assert_eq!(complete.len(), 1);
    assert_eq!(complete[0].kind, OperationKind::Complete);
    repository
        .acknowledge_operations(&[complete[0].op_id.clone()])
        .unwrap();

    repository.clear_runtime_sync_key();
    assert!(
        repository
            .reopen_completed(&id, today_shanghai(), 300)
            .unwrap()
    );
    let deferred = repository.sync_state().unwrap();
    assert_eq!(deferred.deferred_upsert_count, 1);
    assert!(repository.pending_operations(100).unwrap().is_empty());

    repository.configure_sync(configuration).unwrap();
    let recovered = repository.pending_operations(100).unwrap();
    assert_eq!(recovered.len(), 1);
    assert_eq!(recovered[0].kind, OperationKind::Reopen);
    assert_eq!(repository.sync_state().unwrap().deferred_upsert_count, 0);
    repository
        .configure_sync(sync_configuration("vault-a", "device-a", 3))
        .unwrap();
    assert_eq!(repository.pending_operations(100).unwrap().len(), 1);
}

#[test]
fn clearing_history_enqueues_one_tombstone_per_record() {
    let (_directory, mut repository) = open_repository();
    let completed_id = create_task(&mut repository, "已完成", 100);
    let passed_id = create_task(&mut repository, "已 Pass", 101);
    let pending_id = create_task(&mut repository, "保留待办", 102);
    repository.complete(&completed_id, 200).unwrap();
    repository.pass(&passed_id, 201).unwrap();
    let configuration = sync_configuration("vault-clear-history", "device-clear-history", 12);
    repository.configure_sync(configuration.clone()).unwrap();
    let baseline = repository.pending_operations(100).unwrap();
    repository
        .acknowledge_operations(
            &baseline
                .iter()
                .map(|operation| operation.op_id.clone())
                .collect::<Vec<_>>(),
        )
        .unwrap();

    assert_eq!(repository.clear_history(None, 300).unwrap(), 2);
    assert_eq!(repository.clear_history(None, 301).unwrap(), 0);

    let operations = repository.pending_operations(100).unwrap();
    assert_eq!(operations.len(), 2);
    assert!(
        operations
            .iter()
            .all(|operation| operation.kind == OperationKind::Delete)
    );
    let tombstone_ids = operations
        .iter()
        .map(|operation| {
            let WireEntity::Tombstone(tombstone) =
                OperationCodec::open_push(operation, &configuration).unwrap()
            else {
                panic!("历史清除操作应携带 tombstone");
            };
            tombstone.id
        })
        .collect::<HashSet<_>>();
    assert_eq!(tombstone_ids, HashSet::from([completed_id, passed_id]));
    assert!(repository.find(&pending_id).unwrap().is_some());
}

#[test]
fn replacing_binding_preserves_tasks_and_builds_a_fresh_baseline() {
    let (_directory, mut repository) = open_repository();
    let id = create_task(&mut repository, "保留任务", 100);
    let old = sync_configuration("vault-old", "device-old", 4);
    repository.configure_sync(old).unwrap();
    let old_ids = repository
        .pending_operations(100)
        .unwrap()
        .into_iter()
        .map(|operation| operation.op_id)
        .collect::<Vec<_>>();
    repository.acknowledge_operations(&old_ids).unwrap();

    let replacement = sync_configuration("vault-new", "device-new", 8);
    repository
        .replace_sync_binding(replacement.clone())
        .unwrap();
    assert_eq!(repository.find(&id).unwrap().unwrap().title, "保留任务");
    let state = repository.sync_state().unwrap();
    assert_eq!(state.vault_id.as_deref(), Some("vault-new"));
    assert_eq!(state.device_id.as_deref(), Some("device-new"));
    assert_eq!(state.cursor, 0);
    let baseline = repository.pending_operations(100).unwrap();
    assert_eq!(baseline.len(), 1);
    assert!(matches!(
        OperationCodec::open_push(&baseline[0], &replacement).unwrap(),
        WireEntity::Task(_)
    ));
}

#[test]
fn replacing_binding_uses_remote_lamport_floor_across_repeated_switches() {
    let (_directory, mut repository) = open_repository();
    let id = create_task(&mut repository, "跨同步方式保留", 100);
    repository
        .configure_sync(sync_configuration("vault-a", "device-a", 4))
        .unwrap();

    let vault_b = sync_configuration("vault-b", "device-b", 8);
    repository
        .replace_sync_binding_with_lamport_floor(vault_b.clone(), 50)
        .unwrap();
    let first = repository.pending_operations(100).unwrap();
    assert_eq!(first.len(), 1);
    assert_eq!(first[0].lamport, 51);
    assert_eq!(repository.sync_state().unwrap().lamport, 51);
    repository
        .acknowledge_operations(&[first[0].op_id.clone()])
        .unwrap();

    let vault_a = sync_configuration("vault-a", "device-a", 4);
    repository
        .replace_sync_binding_with_lamport_floor(vault_a, 120)
        .unwrap();
    let second = repository.pending_operations(100).unwrap();
    assert_eq!(second.len(), 1);
    assert_eq!(second[0].lamport, 121);
    assert_eq!(
        repository.find(&id).unwrap().unwrap().title,
        "跨同步方式保留"
    );

    repository
        .replace_sync_binding_with_lamport_floor(vault_b, 120)
        .unwrap();
    let repeated = repository.pending_operations(100).unwrap();
    assert_eq!(repeated.len(), 1);
    assert_eq!(repeated[0].lamport, 121);
    assert_eq!(repository.sync_state().unwrap().lamport, 121);
}

#[test]
fn replacing_binding_rejects_invalid_lamport_floor_without_mutation() {
    let (_directory, mut repository) = open_repository();
    create_task(&mut repository, "不可破坏", 100);
    let original = sync_configuration("vault-original", "device-original", 7);
    repository.configure_sync(original).unwrap();
    let before = repository.sync_state().unwrap();

    let error = repository
        .replace_sync_binding_with_lamport_floor(
            sync_configuration("vault-invalid", "device-invalid", 9),
            i64::MAX,
        )
        .unwrap_err();

    assert_eq!(error.code, "validation");
    assert_eq!(repository.sync_state().unwrap(), before);
}

fn pulled(
    configuration: &SyncConfiguration,
    entity: &WireEntity,
    entity_id: &str,
    kind: OperationKind,
    lamport: i64,
    operation_id: &str,
    server_seq: i64,
) -> SyncPulledOperation {
    let envelope = OperationCodec::seal(
        entity,
        configuration,
        operation_id,
        entity_id,
        kind,
        lamport,
        Some(&[lamport as u8; 12]),
    )
    .unwrap();
    SyncPulledOperation {
        server_seq,
        op_id: operation_id.to_owned(),
        device_id: configuration.device_id.clone(),
        entity_id: entity_id.to_owned(),
        kind,
        lamport,
        ciphertext: envelope.ciphertext,
        nonce: envelope.nonce,
        created_at: 500,
    }
}

#[test]
fn remote_apply_is_idempotent_and_tampered_pages_roll_back_cursor_and_data() {
    let (_directory, mut target) = open_repository();
    let target_configuration = sync_configuration("vault-shared", "device-target", 9);
    target.configure_sync(target_configuration).unwrap();
    let source_configuration = sync_configuration("vault-shared", "device-source", 9);
    let task = TodoTask::create(
        "远端任务",
        TimeType::Day,
        today_shanghai(),
        QuestLine::Side,
        false,
        0,
        100,
        None,
        None,
        Some("00000000-0000-4000-8000-000000000901".to_owned()),
    )
    .unwrap();
    let entity = WireEntity::Task(WireTaskPayload::from_task(&task).unwrap());
    let first = pulled(
        &source_configuration,
        &entity,
        &task.id,
        OperationKind::Upsert,
        1,
        "op-remote-0001",
        1,
    );
    let mut duplicate = first.clone();
    duplicate.server_seq = 2;
    target
        .apply_remote_operations(&[first, duplicate], 2)
        .unwrap();
    assert_eq!(target.fetch_all().unwrap(), vec![task.clone()]);
    assert_eq!(target.current_cursor().unwrap(), 2);

    let mut tampered = pulled(
        &source_configuration,
        &WireEntity::Tombstone(WireTombstonePayload::new(&task.id, 700).unwrap()),
        &task.id,
        OperationKind::Delete,
        2,
        "op-remote-0002",
        3,
    );
    tampered.ciphertext.replace_range(0..1, "A");
    assert!(target.apply_remote_operations(&[tampered], 3).is_err());
    assert_eq!(target.current_cursor().unwrap(), 2);
    assert_eq!(target.fetch_all().unwrap(), vec![task]);
}

fn settled_someday(id: &str, state: TaskState, settled_at: i64) -> TodoTask {
    let mut task = TodoTask::create(
        "竞争结算",
        TimeType::Someday,
        today_shanghai(),
        QuestLine::Main,
        false,
        0,
        100,
        None,
        None,
        Some(id.to_owned()),
    )
    .unwrap();
    task.state = state;
    task.updated_at = settled_at;
    task.settled_at = Some(settled_at);
    task
}

#[test]
fn completed_and_pass_conflicts_converge_independent_of_arrival_order() {
    let identifier = "00000000-0000-4000-8000-000000000902";
    let completed = settled_someday(identifier, TaskState::Completed, 200);
    let passed = settled_someday(identifier, TaskState::Pass, 300);
    let source_a = sync_configuration("vault-conflict", "device-a", 6);
    let source_b = sync_configuration("vault-conflict", "device-b", 6);
    let complete = pulled(
        &source_a,
        &WireEntity::Task(WireTaskPayload::from_task(&completed).unwrap()),
        identifier,
        OperationKind::Complete,
        5,
        "op-conflict-a",
        1,
    );
    let pass = pulled(
        &source_b,
        &WireEntity::Task(WireTaskPayload::from_task(&passed).unwrap()),
        identifier,
        OperationKind::Pass,
        6,
        "op-conflict-b",
        2,
    );

    let (_first_dir, mut first) = open_repository();
    first
        .configure_sync(sync_configuration("vault-conflict", "target-1", 6))
        .unwrap();
    first
        .apply_remote_operations(&[complete.clone(), pass.clone()], 2)
        .unwrap();

    let (_second_dir, mut second) = open_repository();
    second
        .configure_sync(sync_configuration("vault-conflict", "target-2", 6))
        .unwrap();
    let mut pass_first = pass;
    pass_first.server_seq = 1;
    let mut complete_second = complete;
    complete_second.server_seq = 2;
    second
        .apply_remote_operations(&[pass_first, complete_second], 2)
        .unwrap();

    let first_task = first.find(identifier).unwrap().unwrap();
    let second_task = second.find(identifier).unwrap().unwrap();
    assert_eq!(first_task, second_task);
    assert_eq!(first_task.state, TaskState::Completed);
    assert_eq!(first_task.settled_at, Some(200));
}

#[test]
fn remote_reopen_allows_expired_once_and_rejects_expired_repeat() {
    let source_configuration = sync_configuration("vault-reopen", "device-source", 8);
    let identifier = "00000000-0000-4000-8000-000000000903";
    let mut once = TodoTask::create(
        "跨周期一次性任务",
        TimeType::Day,
        today_shanghai(),
        QuestLine::Main,
        false,
        0,
        100,
        None,
        None,
        Some(identifier.to_owned()),
    )
    .unwrap();
    once.updated_at = 8_000_000_000_000_000;
    let once_reopen = pulled(
        &source_configuration,
        &WireEntity::Task(WireTaskPayload::from_task(&once).unwrap()),
        identifier,
        OperationKind::Reopen,
        2,
        "op-reopen-once",
        1,
    );
    let (_once_directory, mut once_target) = open_repository();
    once_target
        .configure_sync(sync_configuration("vault-reopen", "device-once-target", 8))
        .unwrap();
    once_target
        .apply_remote_operations(&[once_reopen], 1)
        .unwrap();
    assert_eq!(
        once_target.find(identifier).unwrap().unwrap().state,
        TaskState::Pending
    );

    let mut repeating = once;
    repeating.id = "00000000-0000-4000-8000-000000000904".to_owned();
    repeating.series_id = repeating.id.clone();
    repeating.recurrence = Recurrence::Repeat;
    let repeat_reopen = pulled(
        &source_configuration,
        &WireEntity::Task(WireTaskPayload::from_task(&repeating).unwrap()),
        &repeating.id,
        OperationKind::Reopen,
        3,
        "op-reopen-repeat",
        1,
    );
    let (_repeat_directory, mut repeat_target) = open_repository();
    repeat_target
        .configure_sync(sync_configuration(
            "vault-reopen",
            "device-repeat-target",
            8,
        ))
        .unwrap();
    assert!(
        repeat_target
            .apply_remote_operations(&[repeat_reopen], 1)
            .is_err()
    );
    assert_eq!(repeat_target.current_cursor().unwrap(), 0);
    assert!(repeat_target.find(&repeating.id).unwrap().is_none());
}

#[test]
fn backup_restore_requires_pristine_database_and_rolls_back_invalid_snapshot() {
    let (_source_dir, mut source) = open_repository();
    create_task(&mut source, "备份任务", 100);
    let snapshot = source.make_backup_snapshot(500, None).unwrap();

    let (_target_dir, mut target) = open_repository();
    target.restore_backup_snapshot(&snapshot).unwrap();
    assert_eq!(target.fetch_all().unwrap().len(), 1);
    assert!(target.restore_backup_snapshot(&snapshot).is_err());

    let (_invalid_dir, mut invalid_target) = open_repository();
    let mut invalid_snapshot = snapshot;
    invalid_snapshot
        .tasks
        .push(invalid_snapshot.tasks[0].clone());
    assert!(
        invalid_target
            .restore_backup_snapshot(&invalid_snapshot)
            .is_err()
    );
    assert!(invalid_target.fetch_all().unwrap().is_empty());
    assert!(!invalid_target.sync_state().unwrap().has_sync_history());
}

#[test]
fn backup_tasks_and_sync_binding_roll_back_together_when_baseline_enqueue_fails() {
    let (_source_dir, mut source) = open_repository();
    create_task(&mut source, "原子恢复", 100);
    let credentials = BackupSyncCredentials {
        endpoint: "https://sync.example.test".to_owned(),
        vault_id: "vault-restore".to_owned(),
        device_id: "device-restore".to_owned(),
        device_token: base64url_encode(&[2; 32]),
        vault_key: base64url_encode(&[3; 32]),
    };
    let snapshot = source.make_backup_snapshot(500, None).unwrap();
    let snapshot = BackupSnapshot {
        sync_credentials: Some(credentials),
        ..snapshot
    };

    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("tasks.sqlite");
    let mut target = TaskRepository::open(&path).unwrap();
    let fault_connection = rusqlite::Connection::open(&path).unwrap();
    fault_connection
        .execute_batch(
            "CREATE TRIGGER fail_baseline BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(FAIL, 'injected'); END;",
        )
        .unwrap();
    drop(fault_connection);

    let configuration = sync_configuration("vault-restore", "device-restore", 3);
    assert!(
        target
            .restore_backup_snapshot_and_configure(&snapshot, Some(configuration))
            .is_err()
    );
    assert!(target.fetch_all().unwrap().is_empty());
    let state = target.sync_state().unwrap();
    assert!(!state.has_bound_identity());
    assert!(!state.has_sync_history());
}
