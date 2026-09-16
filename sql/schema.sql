-- ============================================================================
-- AUTOMIX - schema de base de datos (zgaming_web)
--
-- Unico archivo de schema, al dia con produccion. Idempotente:
--   * tablas con CREATE TABLE IF NOT EXISTS (nunca borra datos);
--   * procedimientos con DROP PROCEDURE IF EXISTS + CREATE.
--
-- Depende de accsys.accounts y accsys.servers (AccSys).
-- Uso: mariadb < sql/schema.sql
-- ============================================================================

CREATE DATABASE IF NOT EXISTS `zgaming_web` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

SET FOREIGN_KEY_CHECKS = 0;

-- ----------------------------------------------------------------------------
-- Tablas
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_dm_queue` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `accid` int(11) NOT NULL,
  `proposal_id` int(11) NOT NULL,
  `mode` enum('5v5','2v2','1v1') NOT NULL DEFAULT '5v5',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `sent_at` datetime DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_aviso` (`accid`,`proposal_id`),
  KEY `idx_pendiente` (`sent_at`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_elo` (
  `accid` int(11) NOT NULL,
  `mode` enum('5v5','2v2','1v1') NOT NULL DEFAULT '5v5',
  `elo` int(11) NOT NULL DEFAULT 1000,
  `matches` int(11) NOT NULL DEFAULT 0,
  `wins` int(11) NOT NULL DEFAULT 0,
  `losses` int(11) NOT NULL DEFAULT 0,
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`accid`,`mode`),
  KEY `idx_mix_elo_mode` (`mode`,`elo` DESC,`wins` DESC,`accid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_lobbies` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `mode` enum('5v5','2v2','1v1') NOT NULL DEFAULT '5v5',
  `match_number` int(10) unsigned DEFAULT NULL COMMENT 'Numero de partida dentro de su modalidad; es lo que se ve en la web',
  `status` enum('draft','mapban','ready','live','finished','cancelled') NOT NULL DEFAULT 'draft',
  `captain_a_accid` int(11) NOT NULL COMMENT 'Capitan del equipo A',
  `captain_b_accid` int(11) NOT NULL COMMENT 'Capitan del equipo B',
  `pick_turn` tinyint(3) unsigned DEFAULT 0 COMMENT 'Indice del pick actual en la secuencia 1/2/2/2/1',
  `ban_turn` tinyint(3) unsigned DEFAULT NULL COMMENT 'Indice del ban actual en la secuencia alternada',
  `turn_deadline` datetime DEFAULT NULL COMMENT 'Vencimiento del turno actual; NULL = sin turno activo',
  `map` varchar(64) DEFAULT NULL COMMENT 'Mapa sobreviviente al veto',
  `server_id` int(11) DEFAULT NULL COMMENT 'FK al servidor asignado',
  `server_password` varchar(32) DEFAULT NULL COMMENT 'Password rotativa, visible solo para los 10 del roster',
  `claimed_at` datetime DEFAULT NULL COMMENT 'Cuando el servidor tomó la sala; NULL = sin servidor asignado',
  `heartbeat_at` datetime DEFAULT NULL,
  `join_deadline` datetime DEFAULT NULL COMMENT 'Hasta cuando hay tiempo de que entren los 10; lo fija el servidor al tomar la sala',
  `score_a` tinyint(3) unsigned NOT NULL DEFAULT 0 COMMENT 'Rondas ganadas por el equipo A',
  `score_b` tinyint(3) unsigned NOT NULL DEFAULT 0 COMMENT 'Rondas ganadas por el equipo B',
  `half` tinyint(3) unsigned NOT NULL DEFAULT 0 COMMENT '0 = no arranco, 1 = primer tiempo, 2 = segundo, 3+ = overtime',
  `started_at` datetime DEFAULT NULL COMMENT 'Cuando la partida se puso LIVE de verdad; claimed_at incluiria warmup y cuchillo',
  `finished_at` datetime DEFAULT NULL COMMENT 'Cuando el servidor reportó el resultado',
  `demo_url` varchar(255) DEFAULT NULL,
  `demo_bytes` bigint(20) DEFAULT NULL,
  `demo_ready_at` datetime DEFAULT NULL,
  `is_test` tinyint(1) NOT NULL DEFAULT 0 COMMENT '1 = partida de prueba creada desde el panel; los rivales son de mentira',
  `recreated_from` int(11) DEFAULT NULL COMMENT 'Sala de la que se rehizo esta partida',
  `closed_by_accid` int(11) DEFAULT NULL COMMENT 'Core que cancelo o rehizo la sala',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_mode_number` (`mode`,`match_number`),
  KEY `idx_created_at` (`created_at`),
  KEY `idx_claimable` (`status`,`claimed_at`),
  KEY `idx_recreated_from` (`recreated_from`),
  KEY `idx_status_finished` (`status`,`finished_at`),
  KEY `idx_status_map_finished` (`status`,`map`,`finished_at`),
  KEY `idx_latido` (`status`,`heartbeat_at`),
  KEY `idx_mix_lobbies_mode_status_created` (`mode`,`status`,`created_at`),
  KEY `idx_mix_lobbies_mode_status_finished` (`mode`,`status`,`finished_at`),
  KEY `idx_mix_lobbies_mode_claimable` (`mode`,`status`,`claimed_at`,`is_test`,`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
-- Cada modalidad numera sus partidas por separado: el 1v1 #1 no tiene nada que
-- ver con el 5v5 #1. El contador vive aparte para que dos partidas que se arman
-- a la vez no se peleen el mismo numero.
CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_match_counters` (
  `mode` enum('5v5','2v2','1v1') NOT NULL,
  `last_number` int(10) unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`mode`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_lobby_chat_messages` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `lobby_id` int(11) NOT NULL,
  `accid` int(11) NOT NULL,
  `message` varchar(500) NOT NULL,
  `created_at` datetime(3) NOT NULL DEFAULT current_timestamp(3),
  PRIMARY KEY (`id`),
  KEY `idx_mix_chat_lobby_id` (`lobby_id`,`id`),
  KEY `idx_mix_chat_sender_time` (`lobby_id`,`accid`,`created_at`),
  CONSTRAINT `fk_mix_lobby_chat_lobby` FOREIGN KEY (`lobby_id`) REFERENCES `mix_lobbies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_lobby_maps` (
  `lobby_id` int(11) NOT NULL,
  `map` varchar(64) NOT NULL,
  `banned_by` enum('A','B') DEFAULT NULL COMMENT 'NULL = sigue disponible',
  `ban_order` tinyint(3) unsigned DEFAULT NULL COMMENT 'Orden del ban (0..5), para el historial pick/ban',
  `banned_at` datetime DEFAULT NULL COMMENT 'Cuando se veto, para contarlo en el chat de la sala',
  PRIMARY KEY (`lobby_id`,`map`),
  CONSTRAINT `fk_mix_lobby_maps_lobby` FOREIGN KEY (`lobby_id`) REFERENCES `mix_lobbies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_lobby_players` (
  `lobby_id` int(11) NOT NULL,
  `accid` int(11) NOT NULL,
  `nickname` varchar(64) NOT NULL,
  `team` enum('A','B') DEFAULT NULL COMMENT 'NULL = sin pickear (en el pool)',
  `is_captain` tinyint(1) NOT NULL DEFAULT 0,
  `is_sub` tinyint(1) NOT NULL DEFAULT 0,
  `pick_order` tinyint(3) unsigned DEFAULT NULL COMMENT 'En que turno del draft fue elegido (NULL para capitanes)',
  `picked_at` datetime DEFAULT NULL COMMENT 'Cuando fue elegido, para contarlo en el chat de la sala',
  `kills` smallint(5) unsigned NOT NULL DEFAULT 0,
  `deaths` smallint(5) unsigned NOT NULL DEFAULT 0,
  `assists` smallint(5) unsigned NOT NULL DEFAULT 0,
  `damage` int(10) unsigned DEFAULT NULL,
  `headshots` smallint(5) unsigned DEFAULT NULL,
  `rounds_played` smallint(5) unsigned DEFAULT NULL,
  `elo_before` int(11) DEFAULT NULL,
  `elo_delta` int(11) DEFAULT NULL,
  `connected_at` datetime DEFAULT NULL COMMENT 'Primera vez que el jugador entró al servidor de esta partida',
  `confirmed_at` datetime DEFAULT NULL,
  `abandoned_at` datetime DEFAULT NULL,
  `joined_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`lobby_id`,`accid`),
  KEY `idx_accid` (`accid`),
  CONSTRAINT `fk_mix_lobby_players_lobby` FOREIGN KEY (`lobby_id`) REFERENCES `mix_lobbies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
-- Bases creadas antes de que existieran estas columnas.
ALTER TABLE `zgaming_web`.`mix_lobby_maps` ADD COLUMN IF NOT EXISTS `banned_at` datetime DEFAULT NULL COMMENT 'Cuando se veto, para contarlo en el chat de la sala' AFTER `ban_order`;
ALTER TABLE `zgaming_web`.`mix_lobby_players` ADD COLUMN IF NOT EXISTS `picked_at` datetime DEFAULT NULL COMMENT 'Cuando fue elegido, para contarlo en el chat de la sala' AFTER `pick_order`;
CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_no_shows` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `accid` int(11) NOT NULL,
  `lobby_id` int(11) NOT NULL,
  `strike` tinyint(3) unsigned NOT NULL COMMENT 'Que numero de falta era en ese momento',
  `penalty_seconds` int(11) NOT NULL COMMENT 'Cuanto se le aplico',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_accid` (`accid`),
  KEY `idx_created_at` (`created_at`),
  KEY `fk_mix_no_shows_lobby` (`lobby_id`),
  CONSTRAINT `fk_mix_no_shows_lobby` FOREIGN KEY (`lobby_id`) REFERENCES `mix_lobbies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_penalties` (
  `accid` int(11) NOT NULL,
  `strikes` tinyint(3) unsigned NOT NULL DEFAULT 0 COMMENT 'Faltas acumuladas; se reinician si paso mas de un dia desde la ultima',
  `last_strike_at` datetime DEFAULT NULL,
  `banned_until` datetime DEFAULT NULL COMMENT 'No puede entrar a la cola hasta esta hora',
  `total_no_shows` int(11) NOT NULL DEFAULT 0 COMMENT 'Historico completo, no se reinicia nunca',
  `decline_strikes` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `decline_last_strike_at` datetime DEFAULT NULL,
  `decline_banned_until` datetime DEFAULT NULL,
  `total_declines` int(11) NOT NULL DEFAULT 0,
  `manual_banned_until` datetime DEFAULT NULL COMMENT 'Bloqueo puesto a mano por Core',
  `manual_reason` varchar(200) DEFAULT NULL,
  `manual_by` int(11) DEFAULT NULL COMMENT 'accid de Core que lo puso',
  PRIMARY KEY (`accid`),
  KEY `idx_banned_until` (`banned_until`),
  KEY `idx_decline_banned_until` (`decline_banned_until`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
-- Bases creadas antes del bloqueo manual.
ALTER TABLE `zgaming_web`.`mix_penalties` ADD COLUMN IF NOT EXISTS `manual_banned_until` datetime DEFAULT NULL COMMENT 'Bloqueo puesto a mano por Core' AFTER `total_declines`;
ALTER TABLE `zgaming_web`.`mix_penalties` ADD COLUMN IF NOT EXISTS `manual_reason` varchar(200) DEFAULT NULL AFTER `manual_banned_until`;
ALTER TABLE `zgaming_web`.`mix_penalties` ADD COLUMN IF NOT EXISTS `manual_by` int(11) DEFAULT NULL COMMENT 'accid de Core que lo puso' AFTER `manual_reason`;
CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_queue` (
  `accid` int(11) NOT NULL COMMENT 'Cuenta del jugador (accsys)',
  `mode` enum('5v5','2v2','1v1') NOT NULL DEFAULT '5v5',
  `nickname` varchar(64) NOT NULL COMMENT 'Nick al momento de entrar a la cola',
  `joined_at` timestamp NOT NULL DEFAULT current_timestamp() COMMENT 'Orden FIFO de la cola',
  `heartbeat_at` timestamp NOT NULL DEFAULT current_timestamp() COMMENT 'Ultimo poll del cliente; sirve para expulsar clientes muertos',
  `proposal_id` int(11) DEFAULT NULL,
  `proposal_at` datetime DEFAULT NULL,
  `confirmed_at` datetime DEFAULT NULL,
  PRIMARY KEY (`accid`),
  KEY `idx_joined_at` (`joined_at`),
  KEY `idx_heartbeat` (`heartbeat_at`),
  KEY `idx_proposal` (`proposal_id`),
  KEY `idx_mix_queue_mode_waiting` (`mode`,`proposal_id`,`joined_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_rewards` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `accid` int(11) NOT NULL,
  `kind` enum('daily','weekly') NOT NULL COMMENT 'daily = Gold 1 dia transferible; weekly = Premium 2 dias',
  `period_key` varchar(10) NOT NULL COMMENT 'daily: fecha YYYY-MM-DD; weekly: semana ISO YYYY-Www',
  `lobby_id` int(11) NOT NULL COMMENT 'Partida 5v5 ganada que dio el premio',
  `inventory_item_id` int(11) DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_mix_rewards_period` (`accid`,`kind`,`period_key`),
  KEY `idx_mix_rewards_lobby` (`lobby_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- Cada rechazo de la confirmacion, para el historial de sanciones. Antes solo
-- habia contadores y Core no podia ver cuando fue cada uno.
CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_declines` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `accid` int(11) NOT NULL,
  `mode` enum('5v5','2v2','1v1') NOT NULL DEFAULT '5v5',
  `strike` tinyint(3) unsigned NOT NULL COMMENT 'Que numero de rechazo era en ese momento',
  `penalty_seconds` int(11) NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_mix_declines_accid` (`accid`,`created_at`),
  KEY `idx_mix_declines_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- Bloqueos puestos a mano por Core, con motivo. El vigente vive en
-- mix_penalties.manual_banned_until; esto queda como historial.
CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_manual_blocks` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `accid` int(11) NOT NULL,
  `seconds` int(11) NOT NULL,
  `reason` varchar(200) NOT NULL,
  `core_accid` int(11) NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_mix_manual_blocks_accid` (`accid`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- Estadisticas detalladas: una fila por ronda que manda el servidor.
CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_match_rounds` (
  `lobby_id` int(11) NOT NULL,
  `round` smallint(5) unsigned NOT NULL COMMENT 'Suma del marcador al terminar la ronda',
  `half` tinyint(3) unsigned NOT NULL COMMENT '1, 2, 3+ = overtime',
  `winner` enum('A','B') NOT NULL,
  `reason` enum('eliminacion','bomba','desactivacion','tiempo','otro') NOT NULL DEFAULT 'otro',
  `segment` enum('rifle','awp','pistol','knife') DEFAULT NULL COMMENT 'Arma del tramo; solo 1v1',
  `side_a` enum('T','CT') NOT NULL COMMENT 'Lado del equipo A en esa ronda',
  `score_a` smallint(5) unsigned NOT NULL,
  `score_b` smallint(5) unsigned NOT NULL,
  `money_a` int(11) NOT NULL DEFAULT 0 COMMENT 'Plata del equipo A al terminar el freezetime',
  `money_b` int(11) NOT NULL DEFAULT 0,
  `alive_a` tinyint(3) unsigned NOT NULL DEFAULT 0 COMMENT 'Vivos del equipo A al terminar',
  `alive_b` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`lobby_id`,`round`),
  CONSTRAINT `fk_mix_match_rounds_lobby` FOREIGN KEY (`lobby_id`) REFERENCES `mix_lobbies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_match_kills` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `lobby_id` int(11) NOT NULL,
  `round` smallint(5) unsigned NOT NULL,
  `second` smallint(5) unsigned NOT NULL COMMENT 'Desde que termino el freezetime',
  `attacker` int(11) NOT NULL,
  `victim` int(11) NOT NULL,
  `weapon` varchar(24) NOT NULL,
  `headshot` tinyint(1) NOT NULL DEFAULT 0,
  `assister` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_mix_match_kills_round` (`lobby_id`,`round`),
  CONSTRAINT `fk_mix_match_kills_lobby` FOREIGN KEY (`lobby_id`) REFERENCES `mix_lobbies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_match_damage` (
  `lobby_id` int(11) NOT NULL,
  `round` smallint(5) unsigned NOT NULL,
  `attacker` int(11) NOT NULL,
  `victim` int(11) NOT NULL,
  `damage` smallint(5) unsigned NOT NULL,
  PRIMARY KEY (`lobby_id`,`round`,`attacker`,`victim`),
  CONSTRAINT `fk_mix_match_damage_lobby` FOREIGN KEY (`lobby_id`) REFERENCES `mix_lobbies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `zgaming_web`.`mix_match_utility` (
  `lobby_id` int(11) NOT NULL,
  `round` smallint(5) unsigned NOT NULL,
  `accid` int(11) NOT NULL,
  `he_damage` smallint(5) unsigned NOT NULL DEFAULT 0,
  `flashes` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `plants` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `defuses` tinyint(3) unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`lobby_id`,`round`,`accid`),
  CONSTRAINT `fk_mix_match_utility_lobby` FOREIGN KEY (`lobby_id`) REFERENCES `mix_lobbies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

SET FOREIGN_KEY_CHECKS = 1;

-- ----------------------------------------------------------------------------
-- Procedimientos
-- ----------------------------------------------------------------------------

DELIMITER $$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixCancelLobby`$$
CREATE PROCEDURE `zgaming_web`.`MixCancelLobby`(IN p_lobby_id INT)
BEGIN
    UPDATE zgaming_web.mix_lobbies
    SET status = 'cancelled',
        finished_at = NOW(),
        server_password = NULL
    WHERE id = p_lobby_id AND status IN ('ready', 'live');
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixCancelNoShowLobby`$$
CREATE PROCEDURE `zgaming_web`.`MixCancelNoShowLobby`(IN p_lobby_id INT)
main: BEGIN
    DECLARE v_status VARCHAR(16) DEFAULT NULL;
    DECLARE v_started_at DATETIME DEFAULT NULL;
    DECLARE v_join_deadline DATETIME DEFAULT NULL;
    DECLARE v_accid INT;
    DECLARE v_strikes INT DEFAULT 0;
    DECLARE v_last_strike_at DATETIME DEFAULT NULL;
    DECLARE v_strike INT DEFAULT 0;
    DECLARE v_penalty_seconds INT DEFAULT 0;
    DECLARE v_done TINYINT DEFAULT 0;
    DECLARE v_cancelled TINYINT DEFAULT 0;

    DECLARE missing_players CURSOR FOR
        SELECT accid
        FROM zgaming_web.mix_lobby_players
        WHERE lobby_id = p_lobby_id
          AND team IS NOT NULL
          AND connected_at IS NULL
        ORDER BY accid
        FOR UPDATE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT status, started_at, join_deadline
    INTO v_status, v_started_at, v_join_deadline
    FROM zgaming_web.mix_lobbies
    WHERE id = p_lobby_id
    LIMIT 1
    FOR UPDATE;

    IF v_status = 'live'
       AND v_started_at IS NULL
       AND v_join_deadline IS NOT NULL
       AND v_join_deadline <= NOW() THEN
        /* OPEN ejecuta el SELECT ... FOR UPDATE del cursor: si un JOIN_GAME
         * compite con el timeout, uno de los dos fija primero la verdad de esa
         * fila. Y si ya llegaron todos, no se cancela una sala sana. */
        SET v_done = 0;
        OPEN missing_players;
        FETCH missing_players INTO v_accid;

        IF v_done = 0 THEN
            UPDATE zgaming_web.mix_lobbies
            SET status = 'cancelled',
                finished_at = NOW(),
                server_password = NULL
            WHERE id = p_lobby_id AND status = 'live' AND started_at IS NULL;

            SET v_cancelled = 1;

            missing_loop: LOOP
                -- Materializa la fila antes del SELECT FOR UPDATE. Asi incluso
                -- la primera falta de una cuenta queda protegida por un lock.
                INSERT INTO zgaming_web.mix_penalties (accid)
                VALUES (v_accid)
                ON DUPLICATE KEY UPDATE accid = VALUES(accid);

                SELECT strikes, last_strike_at
                INTO v_strikes, v_last_strike_at
                FROM zgaming_web.mix_penalties
                WHERE accid = v_accid
                FOR UPDATE;

                SET v_strike = IF(
                    v_last_strike_at IS NULL
                    OR v_last_strike_at < DATE_SUB(NOW(), INTERVAL 24 HOUR),
                    1,
                    LEAST(v_strikes + 1, 255)
                );
                SET v_penalty_seconds = CASE
                    WHEN v_strike = 1 THEN 120
                    WHEN v_strike = 2 THEN 600
                    WHEN v_strike = 3 THEN 3600
                    ELSE 86400
                END;

                UPDATE zgaming_web.mix_penalties
                SET strikes = v_strike,
                    last_strike_at = NOW(),
                    banned_until = DATE_ADD(NOW(), INTERVAL v_penalty_seconds SECOND),
                    total_no_shows = total_no_shows + 1
                WHERE accid = v_accid;

                INSERT INTO zgaming_web.mix_no_shows
                    (accid, lobby_id, strike, penalty_seconds)
                VALUES
                    (v_accid, p_lobby_id, v_strike, v_penalty_seconds);

                FETCH missing_players INTO v_accid;
                IF v_done = 1 THEN
                    LEAVE missing_loop;
                END IF;
            END LOOP;
        END IF;

        CLOSE missing_players;
    END IF;

    COMMIT;

    SELECT v_cancelled AS cancelled;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixCancelNoShowLobbyV2`$$
CREATE PROCEDURE `zgaming_web`.`MixCancelNoShowLobbyV2`(
    IN p_lobby_id INT,
    IN p_absent LONGTEXT
)
main: BEGIN
    DECLARE v_status VARCHAR(16) DEFAULT NULL;
    DECLARE v_started_at DATETIME DEFAULT NULL;
    DECLARE v_join_deadline DATETIME DEFAULT NULL;
    DECLARE v_accid INT;
    DECLARE v_strikes INT DEFAULT 0;
    DECLARE v_last_strike_at DATETIME DEFAULT NULL;
    DECLARE v_strike INT DEFAULT 0;
    DECLARE v_penalty_seconds INT DEFAULT 0;
    DECLARE v_done TINYINT DEFAULT 0;
    DECLARE v_cancelled TINYINT DEFAULT 0;

    DECLARE missing_players CURSOR FOR
        SELECT accid
        FROM zgaming_web.mix_lobby_players
        WHERE lobby_id = p_lobby_id
          AND team IS NOT NULL
          AND connected_at IS NULL
        ORDER BY accid
        FOR UPDATE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT status, started_at, join_deadline
    INTO v_status, v_started_at, v_join_deadline
    FROM zgaming_web.mix_lobbies
    WHERE id = p_lobby_id
    LIMIT 1
    FOR UPDATE;

    IF v_status = 'live'
       AND v_started_at IS NULL
       AND v_join_deadline IS NOT NULL
       AND v_join_deadline <= NOW() THEN
        
        IF p_absent IS NOT NULL AND JSON_VALID(p_absent) THEN
            UPDATE zgaming_web.mix_lobby_players p
            JOIN JSON_TABLE(p_absent, '$[*]' COLUMNS(
                accid INT PATH '$'
            )) a ON a.accid = p.accid
            SET p.connected_at = NULL
            WHERE p.lobby_id = p_lobby_id
              AND p.team IS NOT NULL;
        END IF;

        
        SET v_done = 0;
        OPEN missing_players;
        FETCH missing_players INTO v_accid;

        IF v_done = 0 THEN
            UPDATE zgaming_web.mix_lobbies
            SET status = 'cancelled',
                finished_at = NOW(),
                server_password = NULL
            WHERE id = p_lobby_id AND status = 'live' AND started_at IS NULL;

            SET v_cancelled = 1;

            missing_loop: LOOP
                
                
                INSERT INTO zgaming_web.mix_penalties (accid)
                VALUES (v_accid)
                ON DUPLICATE KEY UPDATE accid = VALUES(accid);

                SELECT strikes, last_strike_at
                INTO v_strikes, v_last_strike_at
                FROM zgaming_web.mix_penalties
                WHERE accid = v_accid
                FOR UPDATE;

                SET v_strike = IF(
                    v_last_strike_at IS NULL
                    OR v_last_strike_at < DATE_SUB(NOW(), INTERVAL 24 HOUR),
                    1,
                    LEAST(v_strikes + 1, 255)
                );
                SET v_penalty_seconds = CASE
                    WHEN v_strike = 1 THEN 120
                    WHEN v_strike = 2 THEN 600
                    WHEN v_strike = 3 THEN 3600
                    ELSE 86400
                END;

                UPDATE zgaming_web.mix_penalties
                SET strikes = v_strike,
                    last_strike_at = NOW(),
                    banned_until = DATE_ADD(NOW(), INTERVAL v_penalty_seconds SECOND),
                    total_no_shows = total_no_shows + 1
                WHERE accid = v_accid;

                INSERT INTO zgaming_web.mix_no_shows
                    (accid, lobby_id, strike, penalty_seconds)
                VALUES
                    (v_accid, p_lobby_id, v_strike, v_penalty_seconds);

                FETCH missing_players INTO v_accid;
                IF v_done = 1 THEN
                    LEAVE missing_loop;
                END IF;
            END LOOP;
        END IF;

        CLOSE missing_players;
    END IF;

    COMMIT;

    SELECT v_cancelled AS cancelled;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixClaimLobby`$$
CREATE PROCEDURE `zgaming_web`.`MixClaimLobby`(IN p_server_id INT)
BEGIN
    DECLARE v_lobby_id INT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT id INTO v_lobby_id
    FROM zgaming_web.mix_lobbies
    WHERE status = 'ready'
      AND claimed_at IS NULL
      AND is_test = 0
      AND mode = '5v5'
    ORDER BY id ASC
    LIMIT 1
    FOR UPDATE;

    IF v_lobby_id IS NOT NULL THEN
        UPDATE zgaming_web.mix_lobbies
        SET status = 'live',
            server_id = p_server_id,
            claimed_at = NOW(),
            heartbeat_at = NOW(),
            join_deadline = DATE_ADD(NOW(), INTERVAL 5 MINUTE)
        WHERE id = v_lobby_id AND claimed_at IS NULL;

        IF ROW_COUNT() = 0 THEN
            SET v_lobby_id = NULL;
        END IF;
    END IF;

    COMMIT;

    SELECT id, map, server_password, score_a, score_b, half
    FROM zgaming_web.mix_lobbies
    WHERE id = v_lobby_id;

    SELECT accid,
           CASE team WHEN 'A' THEN 1 WHEN 'B' THEN 2 ELSE 0 END AS team
    FROM zgaming_web.mix_lobby_players
    WHERE lobby_id = v_lobby_id
      AND team IS NOT NULL
      AND abandoned_at IS NULL
    ORDER BY team, is_captain DESC, pick_order;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixClaimLobbyV2`$$
CREATE PROCEDURE `zgaming_web`.`MixClaimLobbyV2`(
    IN p_server_id INT,
    IN p_mode VARCHAR(8)
)
BEGIN
    DECLARE v_lobby_id INT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT id INTO v_lobby_id
    FROM zgaming_web.mix_lobbies
    WHERE status = 'ready'
      AND claimed_at IS NULL
      AND is_test = 0
      AND (p_mode = 'all' OR mode = p_mode)
      AND p_mode IN ('all', '5v5', '2v2')
    ORDER BY id ASC
    LIMIT 1
    FOR UPDATE;

    IF v_lobby_id IS NOT NULL THEN
        UPDATE zgaming_web.mix_lobbies
        SET status = 'live',
            server_id = p_server_id,
            claimed_at = NOW(),
            heartbeat_at = NOW(),
            join_deadline = DATE_ADD(NOW(), INTERVAL 5 MINUTE)
        WHERE id = v_lobby_id AND claimed_at IS NULL;

        IF ROW_COUNT() = 0 THEN
            SET v_lobby_id = NULL;
        END IF;
    END IF;

    COMMIT;

    SELECT id, map, server_password, score_a, score_b, half, mode,
           CASE mode WHEN '1v1' THEN 1 WHEN '2v2' THEN 2 ELSE 5 END AS team_size
    FROM zgaming_web.mix_lobbies
    WHERE id = v_lobby_id;

    SELECT accid,
           CASE team WHEN 'A' THEN 1 WHEN 'B' THEN 2 ELSE 0 END AS team
    FROM zgaming_web.mix_lobby_players
    WHERE lobby_id = v_lobby_id
      AND team IS NOT NULL
      AND abandoned_at IS NULL
    ORDER BY team, is_captain DESC, pick_order;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixFinishMatch`$$
CREATE PROCEDURE `zgaming_web`.`MixFinishMatch`(
    IN p_lobby_id INT,
    IN p_score_a INT,
    IN p_score_b INT,
    IN p_stats LONGTEXT
)
main: BEGIN
    DECLARE v_mode VARCHAR(4) DEFAULT NULL;
    DECLARE v_status VARCHAR(16) DEFAULT NULL;
    DECLARE v_avg_a DOUBLE DEFAULT 1000;
    DECLARE v_avg_b DOUBLE DEFAULT 1000;
    DECLARE v_exp_a DOUBLE;
    DECLARE v_res_a DOUBLE;
    DECLARE v_delta_a INT;
    DECLARE v_ya_contada INT DEFAULT 0;
    
    DECLARE v_abandon_penalty INT DEFAULT 25;
    DECLARE v_stats LONGTEXT DEFAULT '[]';

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT mode, status INTO v_mode, v_status
    FROM zgaming_web.mix_lobbies
    WHERE id = p_lobby_id
    LIMIT 1
    FOR UPDATE;

    IF v_mode IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'MIX_LOBBY_NOT_FOUND';
    END IF;

    
    IF v_status <> 'live' THEN
        COMMIT;
        LEAVE main;
    END IF;

    IF p_stats IS NOT NULL AND JSON_VALID(p_stats) THEN
        SET v_stats = p_stats;

        UPDATE zgaming_web.mix_lobby_players p
        JOIN JSON_TABLE(p_stats, '$[*]' COLUMNS(
            accid       INT PATH '$.a',
            kills       INT PATH '$.k',
            deaths      INT PATH '$.d',
            assists     INT PATH '$.s',
            damage      INT PATH '$.m',
            headshots   INT PATH '$.h',
            rounds      INT PATH '$.r'
        )) s ON s.accid = p.accid
        SET p.kills         = s.kills,
            p.deaths        = s.deaths,
            p.assists       = s.assists,
            p.damage        = s.damage,
            p.headshots     = s.headshots,
            p.rounds_played = s.rounds
        WHERE p.lobby_id = p_lobby_id;
    END IF;

    SELECT COUNT(*) INTO v_ya_contada
    FROM zgaming_web.mix_lobby_players
    WHERE lobby_id = p_lobby_id AND elo_delta IS NOT NULL AND abandoned_at IS NULL;

    IF v_ya_contada = 0 AND p_score_a <> p_score_b THEN
        INSERT INTO zgaming_web.mix_elo (accid, mode)
        SELECT p.accid, v_mode
        FROM zgaming_web.mix_lobby_players p
        WHERE p.lobby_id = p_lobby_id
          AND p.team IS NOT NULL
          AND p.abandoned_at IS NULL
        ON DUPLICATE KEY UPDATE accid = VALUES(accid);

        SELECT AVG(e.elo) INTO v_avg_a
        FROM zgaming_web.mix_lobby_players p
        JOIN zgaming_web.mix_elo e ON e.accid = p.accid AND e.mode = v_mode
        WHERE p.lobby_id = p_lobby_id AND p.team = 'A' AND p.abandoned_at IS NULL;

        SELECT AVG(e.elo) INTO v_avg_b
        FROM zgaming_web.mix_lobby_players p
        JOIN zgaming_web.mix_elo e ON e.accid = p.accid AND e.mode = v_mode
        WHERE p.lobby_id = p_lobby_id AND p.team = 'B' AND p.abandoned_at IS NULL;

        SET v_avg_a = COALESCE(v_avg_a, 1000);
        SET v_avg_b = COALESCE(v_avg_b, 1000);
        SET v_exp_a = 1 / (1 + POW(10, (v_avg_b - v_avg_a) / 400));
        SET v_res_a = IF(p_score_a > p_score_b, 1, 0);
        SET v_delta_a = ROUND(50 * (v_res_a - v_exp_a));

        IF v_delta_a = 0 THEN
            SET v_delta_a = IF(v_res_a = 1, 1, -1);
        END IF;

        UPDATE zgaming_web.mix_lobby_players p
        JOIN zgaming_web.mix_elo e ON e.accid = p.accid AND e.mode = v_mode
        SET p.elo_before = e.elo,
            p.elo_delta  = IF(p.is_sub = 1,
                              GREATEST(0, IF(p.team = 'A', v_delta_a, -v_delta_a)),
                              IF(p.team = 'A', v_delta_a, -v_delta_a))
        WHERE p.lobby_id = p_lobby_id
          AND p.team IS NOT NULL
          AND p.abandoned_at IS NULL;

        UPDATE zgaming_web.mix_elo e
        JOIN zgaming_web.mix_lobby_players p
          ON p.accid = e.accid AND e.mode = v_mode
        SET e.elo     = GREATEST(100, e.elo + p.elo_delta),
            e.matches = e.matches + 1,
            e.wins    = e.wins   + IF(p.elo_delta > 0, 1, 0),
            e.losses  = e.losses + IF(p.elo_delta < 0, 1, 0)
        WHERE p.lobby_id = p_lobby_id
          AND p.team IS NOT NULL
          AND p.abandoned_at IS NULL;

        
        DROP TEMPORARY TABLE IF EXISTS tmp_mix_abandons;

        CREATE TEMPORARY TABLE tmp_mix_abandons (
            accid      INT NOT NULL PRIMARY KEY,
            target     INT NOT NULL,
            prev_delta INT NULL
        );

        INSERT INTO tmp_mix_abandons (accid, target, prev_delta)
        SELECT p.accid,
               CASE
                   WHEN COALESCE(r.returned, 0) = 1
                        AND IF(p.team = 'A', v_delta_a, -v_delta_a) > 0
                       THEN GREATEST(1, ROUND(IF(p.team = 'A', v_delta_a, -v_delta_a) / 2))
                   WHEN p.is_sub = 1
                       THEN -v_abandon_penalty
                   ELSE LEAST(IF(p.team = 'A', v_delta_a, -v_delta_a), -v_abandon_penalty)
               END,
               p.elo_delta
        FROM zgaming_web.mix_lobby_players p
        LEFT JOIN (
            
            SELECT j.accid, MAX(j.returned) AS returned
            FROM JSON_TABLE(v_stats, '$[*]' COLUMNS(
                accid    INT PATH '$.a',
                returned INT PATH '$.b'
            )) j
            GROUP BY j.accid
        ) r ON r.accid = p.accid
        WHERE p.lobby_id = p_lobby_id
          AND p.team IS NOT NULL
          AND p.abandoned_at IS NOT NULL;

        INSERT INTO zgaming_web.mix_elo (accid, mode)
        SELECT t.accid, v_mode
        FROM tmp_mix_abandons t
        ON DUPLICATE KEY UPDATE accid = VALUES(accid);

        
        UPDATE zgaming_web.mix_lobby_players p
        JOIN tmp_mix_abandons t ON t.accid = p.accid
        JOIN zgaming_web.mix_elo e ON e.accid = p.accid AND e.mode = v_mode
        SET p.elo_before = e.elo
        WHERE p.lobby_id = p_lobby_id
          AND t.prev_delta IS NULL;

        
        UPDATE zgaming_web.mix_elo e
        JOIN tmp_mix_abandons t ON t.accid = e.accid AND e.mode = v_mode
        SET e.elo     = GREATEST(100, e.elo + t.target - COALESCE(t.prev_delta, 0)),
            e.matches = e.matches + IF(t.prev_delta IS NULL, 1, 0),
            e.wins    = e.wins + IF(t.target > 0, 1, 0),
            e.losses  = e.losses + IF(t.prev_delta IS NULL,
                                      IF(t.target < 0, 1, 0),
                                      IF(t.target > 0, -1, 0));

        UPDATE zgaming_web.mix_lobby_players p
        JOIN tmp_mix_abandons t ON t.accid = p.accid
        SET p.elo_delta = t.target
        WHERE p.lobby_id = p_lobby_id;

        DROP TEMPORARY TABLE IF EXISTS tmp_mix_abandons;
    END IF;

    UPDATE zgaming_web.mix_lobbies
    SET status = 'finished',
        score_a = p_score_a,
        score_b = p_score_b,
        finished_at = NOW(),
        server_password = NULL
    WHERE id = p_lobby_id AND status = 'live';

    IF p_score_a <> p_score_b THEN
        CALL zgaming_web.MixGrantMatchRewards(p_lobby_id, IF(p_score_a > p_score_b, 'A', 'B'));
    END IF;

    COMMIT;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixGetLobbyForServer`$$
CREATE PROCEDURE `zgaming_web`.`MixGetLobbyForServer`(
    IN p_server_id INT,
    IN p_with_roster TINYINT
)
BEGIN
    DECLARE v_lobby_id INT DEFAULT NULL;

    SELECT id INTO v_lobby_id
    FROM zgaming_web.mix_lobbies
    WHERE server_id = p_server_id
      AND status = 'live'
      AND is_test = 0
      AND mode = '5v5'
    ORDER BY id DESC
    LIMIT 1;

    SELECT id, map, server_password, score_a, score_b, half
    FROM zgaming_web.mix_lobbies
    WHERE id = v_lobby_id;

    IF p_with_roster = 1 THEN
        SELECT accid,
               CASE team WHEN 'A' THEN 1 WHEN 'B' THEN 2 ELSE 0 END AS team
        FROM zgaming_web.mix_lobby_players
        WHERE lobby_id = v_lobby_id
          AND team IS NOT NULL
          AND abandoned_at IS NULL
        ORDER BY team, is_captain DESC, pick_order;
    END IF;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixGetLobbyForServerV2`$$
CREATE PROCEDURE `zgaming_web`.`MixGetLobbyForServerV2`(
    IN p_server_id INT,
    IN p_with_roster TINYINT
)
BEGIN
    DECLARE v_lobby_id INT DEFAULT NULL;

    SELECT id INTO v_lobby_id
    FROM zgaming_web.mix_lobbies
    WHERE server_id = p_server_id AND status = 'live' AND is_test = 0
    ORDER BY id DESC
    LIMIT 1;

    SELECT id, map, server_password, score_a, score_b, half, mode,
           CASE mode WHEN '1v1' THEN 1 WHEN '2v2' THEN 2 ELSE 5 END AS team_size
    FROM zgaming_web.mix_lobbies
    WHERE id = v_lobby_id;

    IF p_with_roster = 1 THEN
        SELECT accid,
               CASE team WHEN 'A' THEN 1 WHEN 'B' THEN 2 ELSE 0 END AS team
        FROM zgaming_web.mix_lobby_players
        WHERE lobby_id = v_lobby_id
          AND team IS NOT NULL
          AND abandoned_at IS NULL
        ORDER BY team, is_captain DESC, pick_order;
    END IF;
END$$

-- Premios por ganar partidas 5v5 (no de prueba, sin haber abandonado):
--   * semanal: la primera victoria de la semana (lunes a domingo) da un
--     Premium de 2 dias, ligado a la cuenta;
--   * diario: la primera victoria del dia da un Gold de 1 dia transferible,
--     como mucho una vez cada 3 dias.
-- Se llama desde MixFinishMatch, dentro de su transaccion. No devuelve filas:
-- el plugin lee la respuesta de MixFinishMatch y un resultado de mas le
-- desordena la conexion. Por eso inserta directo en el inventario en vez de
-- usar inventory_grant_item, que termina con un SELECT.
-- Un error aca no puede dejar la partida sin cerrar: se deshace solo lo del
-- premio (SAVEPOINT) y la partida sigue su curso.
DROP PROCEDURE IF EXISTS `zgaming_web`.`MixGrantMatchRewards`$$
CREATE PROCEDURE `zgaming_web`.`MixGrantMatchRewards`(
    IN p_lobby_id INT,
    IN p_winner_team CHAR(1)
)
main: BEGIN
    DECLARE v_mode VARCHAR(4) DEFAULT NULL;
    DECLARE v_is_test TINYINT DEFAULT 1;
    DECLARE v_day VARCHAR(10);
    DECLARE v_week VARCHAR(10);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK TO SAVEPOINT mix_rewards;
    END;

    SAVEPOINT mix_rewards;

    SELECT mode, is_test INTO v_mode, v_is_test
    FROM zgaming_web.mix_lobbies
    WHERE id = p_lobby_id
    LIMIT 1;

    IF v_mode IS NULL OR v_mode <> '5v5' OR v_is_test <> 0 OR p_winner_team NOT IN ('A', 'B') THEN
        LEAVE main;
    END IF;

    -- La base corre en hora de Chile (-03:00), igual que la web.
    SET v_day  = DATE_FORMAT(CURDATE(), '%Y-%m-%d');
    SET v_week = CONCAT(LEFT(YEARWEEK(CURDATE(), 3), 4), '-W', RIGHT(YEARWEEK(CURDATE(), 3), 2));

    -- Reservar primero: la clave unica evita entregar dos veces el mismo
    -- periodo aunque MixFinishMatch se repita.
    INSERT IGNORE INTO zgaming_web.mix_rewards (accid, kind, period_key, lobby_id)
    SELECT p.accid, 'weekly', v_week, p_lobby_id
    FROM zgaming_web.mix_lobby_players p
    WHERE p.lobby_id = p_lobby_id
      AND p.team = p_winner_team
      AND p.abandoned_at IS NULL;

    -- Diario: si el ultimo Gold fue hace menos de 3 dias, no toca.
    INSERT IGNORE INTO zgaming_web.mix_rewards (accid, kind, period_key, lobby_id)
    SELECT p.accid, 'daily', v_day, p_lobby_id
    FROM zgaming_web.mix_lobby_players p
    WHERE p.lobby_id = p_lobby_id
      AND p.team = p_winner_team
      AND p.abandoned_at IS NULL
      AND NOT EXISTS (
          SELECT 1
          FROM zgaming_web.mix_rewards d
          WHERE d.accid = p.accid
            AND d.kind = 'daily'
            AND d.period_key > DATE_FORMAT(CURDATE() - INTERVAL 3 DAY, '%Y-%m-%d')
      );

    INSERT INTO zgaming_web.inventory_items (
        accid, name, description, icon, color, item_type,
        privilege_access, privilege_server_id, privilege_duration_days,
        require_access, revoke_on_access_loss, transferable, allow_server_change,
        status, granted_by, grant_reason, grant_source
    )
    SELECT r.accid,
           IF(r.kind = 'weekly', 'Premium 2 días (MIX semanal)', 'Gold 1 día (MIX diario)'),
           IF(r.kind = 'weekly',
              'Premio por ganar tu primera partida 5v5 de la semana.',
              'Premio por ganar tu primera partida 5v5 del día. Puedes transferirlo.'),
           'Crown', '#f59e0b', 'privilege',
           IF(r.kind = 'weekly', 'g', 'h'), NULL, IF(r.kind = 'weekly', 2, 1),
           NULL, 0, IF(r.kind = 'weekly', 0, 1), 0,
           'available', NULL,
           CONCAT('MIX ', IF(r.kind = 'weekly', 'semanal ', 'diario '), r.period_key, ', partida #', r.lobby_id),
           'event'
    FROM zgaming_web.mix_rewards r
    WHERE r.lobby_id = p_lobby_id
      AND r.inventory_item_id IS NULL;

    UPDATE zgaming_web.mix_rewards r
    JOIN zgaming_web.inventory_items i
      ON i.accid = r.accid
     AND i.grant_reason = CONCAT('MIX ', IF(r.kind = 'weekly', 'semanal ', 'diario '), r.period_key, ', partida #', r.lobby_id)
    SET r.inventory_item_id = i.id
    WHERE r.lobby_id = p_lobby_id
      AND r.inventory_item_id IS NULL;

    INSERT INTO zgaming_web.inventory_logs (item_id, accid, action, details, performed_by)
    SELECT r.inventory_item_id, r.accid, 'granted',
           JSON_OBJECT('source', 'event', 'reason', 'mix_reward', 'kind', r.kind,
                       'period', r.period_key, 'lobby_id', r.lobby_id),
           NULL
    FROM zgaming_web.mix_rewards r
    WHERE r.lobby_id = p_lobby_id
      AND r.inventory_item_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM zgaming_web.inventory_logs l
          WHERE l.item_id = r.inventory_item_id AND l.action = 'granted'
      );

    INSERT IGNORE INTO zgaming_web.notifications
        (user_accid, type, title, message, link, notification_key, metadata)
    SELECT r.accid, 'gift_received',
           IF(r.kind = 'weekly', 'Premio MIX semanal', 'Premio MIX diario'),
           IF(r.kind = 'weekly',
              CONCAT('Ganaste tu primera partida 5v5 de la semana (#', r.lobby_id, '). Recibiste Premium 2 días en tu inventario.'),
              CONCAT('Ganaste tu primera partida 5v5 del día (#', r.lobby_id, '). Recibiste Gold 1 día transferible en tu inventario.')),
           '/account/inventory',
           CONCAT('mix_reward_', r.kind, '_', r.period_key),
           JSON_OBJECT('lobby_id', r.lobby_id, 'inventory_item_id', r.inventory_item_id)
    FROM zgaming_web.mix_rewards r
    WHERE r.lobby_id = p_lobby_id;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixHeartbeat`$$
CREATE PROCEDURE `zgaming_web`.`MixHeartbeat`(
    IN p_lobby_id INT
)
BEGIN
    UPDATE zgaming_web.mix_lobbies
    SET heartbeat_at = NOW()
    WHERE id = p_lobby_id AND status = 'live';
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixPlayerAbandoned`$$
CREATE PROCEDURE `zgaming_web`.`MixPlayerAbandoned`(
    IN p_lobby_id INT,
    IN p_accid INT
)
BEGIN
    UPDATE zgaming_web.mix_lobby_players
    SET abandoned_at = NOW()
    WHERE lobby_id = p_lobby_id AND accid = p_accid AND abandoned_at IS NULL;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixPlayerConnected`$$
CREATE PROCEDURE `zgaming_web`.`MixPlayerConnected`(IN p_lobby_id INT, IN p_accid INT)
BEGIN
    UPDATE zgaming_web.mix_lobby_players
    SET connected_at = NOW()
    WHERE lobby_id = p_lobby_id AND accid = p_accid AND connected_at IS NULL;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixRecordRound`$$
-- Guarda el detalle de una ronda. Idempotente: si el servidor la reenvia, la
-- reemplaza entera. No devuelve result sets y un JSON invalido solo deja la
-- ronda sin bajas, daño ni utilidad.
CREATE PROCEDURE `zgaming_web`.`MixRecordRound`(
    IN p_lobby_id INT,
    IN p_round INT,
    IN p_half INT,
    IN p_winner VARCHAR(1),
    IN p_reason VARCHAR(16),
    IN p_side_a VARCHAR(2),
    IN p_score_a INT,
    IN p_score_b INT,
    IN p_data LONGTEXT
)
proc: BEGIN
    DECLARE v_data LONGTEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_round IS NULL OR p_round <= 0 OR p_winner NOT IN ('A', 'B')
        OR NOT EXISTS (SELECT 1 FROM zgaming_web.mix_lobbies WHERE id = p_lobby_id) THEN
        LEAVE proc;
    END IF;

    SET v_data = IF(p_data IS NOT NULL AND JSON_VALID(p_data), p_data, '{}');

    START TRANSACTION;

    INSERT INTO zgaming_web.mix_match_rounds
        (lobby_id, round, half, winner, reason, segment, side_a, score_a, score_b, money_a, money_b, alive_a, alive_b)
    VALUES
        (p_lobby_id, p_round, GREATEST(COALESCE(p_half, 1), 1), p_winner,
         IF(p_reason IN ('eliminacion', 'bomba', 'desactivacion', 'tiempo'), p_reason, 'otro'),
         NULLIF(JSON_VALUE(v_data, '$.sg'), ''),
         IF(p_side_a = 'CT', 'CT', 'T'),
         GREATEST(COALESCE(p_score_a, 0), 0), GREATEST(COALESCE(p_score_b, 0), 0),
         COALESCE(JSON_VALUE(v_data, '$.ma'), 0), COALESCE(JSON_VALUE(v_data, '$.mb'), 0),
         COALESCE(JSON_VALUE(v_data, '$.va'), 0), COALESCE(JSON_VALUE(v_data, '$.vb'), 0))
    ON DUPLICATE KEY UPDATE
        half = VALUES(half), winner = VALUES(winner), reason = VALUES(reason),
        segment = VALUES(segment), side_a = VALUES(side_a),
        score_a = VALUES(score_a), score_b = VALUES(score_b), money_a = VALUES(money_a),
        money_b = VALUES(money_b), alive_a = VALUES(alive_a), alive_b = VALUES(alive_b);

    DELETE FROM zgaming_web.mix_match_kills WHERE lobby_id = p_lobby_id AND round = p_round;
    DELETE FROM zgaming_web.mix_match_damage WHERE lobby_id = p_lobby_id AND round = p_round;
    DELETE FROM zgaming_web.mix_match_utility WHERE lobby_id = p_lobby_id AND round = p_round;

    INSERT INTO zgaming_web.mix_match_kills
        (lobby_id, round, second, attacker, victim, weapon, headshot, assister)
    SELECT p_lobby_id, p_round, GREATEST(COALESCE(k.sec, 0), 0), k.attacker, k.victim,
           LEFT(COALESCE(k.weapon, 'otro'), 24), IF(k.hs = 1, 1, 0), NULLIF(k.assister, 0)
    FROM JSON_TABLE(v_data, '$.k[*]' COLUMNS(
        sec      INT PATH '$[0]',
        attacker INT PATH '$[1]',
        victim   INT PATH '$[2]',
        weapon   VARCHAR(32) PATH '$[3]',
        hs       INT PATH '$[4]',
        assister INT PATH '$[5]'
    )) k
    WHERE k.attacker > 0 AND k.victim > 0;

    INSERT INTO zgaming_web.mix_match_damage (lobby_id, round, attacker, victim, damage)
    SELECT p_lobby_id, p_round, d.attacker, d.victim, LEAST(SUM(d.damage), 65535)
    FROM JSON_TABLE(v_data, '$.d[*]' COLUMNS(
        attacker INT PATH '$[0]',
        victim   INT PATH '$[1]',
        damage   INT PATH '$[2]'
    )) d
    WHERE d.attacker > 0 AND d.victim > 0 AND d.attacker <> d.victim AND d.damage > 0
    GROUP BY d.attacker, d.victim;

    INSERT INTO zgaming_web.mix_match_utility (lobby_id, round, accid, he_damage, flashes, plants, defuses)
    SELECT p_lobby_id, p_round, u.accid, LEAST(SUM(u.he), 65535), LEAST(SUM(u.fl), 255),
           LEAST(SUM(u.pl), 255), LEAST(SUM(u.de), 255)
    FROM JSON_TABLE(v_data, '$.u[*]' COLUMNS(
        accid INT PATH '$[0]',
        he    INT PATH '$[1]',
        fl    INT PATH '$[2]',
        pl    INT PATH '$[3]',
        de    INT PATH '$[4]'
    )) u
    WHERE u.accid > 0
    GROUP BY u.accid;

    COMMIT;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixReplacePlayer`$$
CREATE PROCEDURE `zgaming_web`.`MixReplacePlayer`(
    IN p_lobby_id INT,
    IN p_old_accid INT,
    IN p_new_accid INT
)
BEGIN
    DECLARE v_team ENUM('A','B') DEFAULT NULL;
    DECLARE v_nickname VARCHAR(64) DEFAULT '';

    SELECT team INTO v_team
    FROM zgaming_web.mix_lobby_players
    WHERE lobby_id = p_lobby_id AND accid = p_old_accid
    LIMIT 1;

    IF v_team IS NOT NULL THEN
        SELECT COALESCE(nickname, CONCAT('#', p_new_accid)) INTO v_nickname
        FROM accsys.accounts WHERE accid = p_new_accid LIMIT 1;

        INSERT INTO zgaming_web.mix_lobby_players
            (lobby_id, accid, nickname, team, is_captain, is_sub, connected_at)
        VALUES (p_lobby_id, p_new_accid, COALESCE(NULLIF(v_nickname, ''), CONCAT('#', p_new_accid)), v_team, 0, 1, NOW())
        ON DUPLICATE KEY UPDATE
            team = VALUES(team),
            is_sub = 1,
            connected_at = NOW();
    END IF;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixReplacePlayerWithStats`$$
CREATE PROCEDURE `zgaming_web`.`MixReplacePlayerWithStats`(
    IN p_lobby_id INT,
    IN p_old_accid INT,
    IN p_new_accid INT,
    IN p_old_stats LONGTEXT
)
BEGIN
    DECLARE v_team ENUM('A','B') DEFAULT NULL;
    DECLARE v_nickname VARCHAR(64) DEFAULT '';

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT team INTO v_team
    FROM zgaming_web.mix_lobby_players
    WHERE lobby_id = p_lobby_id AND accid = p_old_accid
    LIMIT 1;

    IF p_old_stats IS NOT NULL AND JSON_VALID(p_old_stats) THEN
        UPDATE zgaming_web.mix_lobby_players p
        JOIN JSON_TABLE(p_old_stats, '$[*]' COLUMNS(
            accid       INT PATH '$.a',
            kills       INT PATH '$.k',
            deaths      INT PATH '$.d',
            assists     INT PATH '$.s',
            damage      INT PATH '$.m',
            headshots   INT PATH '$.h',
            rounds      INT PATH '$.r'
        )) s ON s.accid = p.accid
        SET p.kills         = s.kills,
            p.deaths        = s.deaths,
            p.assists       = s.assists,
            p.damage        = s.damage,
            p.headshots     = s.headshots,
            p.rounds_played = s.rounds
        WHERE p.lobby_id = p_lobby_id AND p.accid = p_old_accid;
    END IF;

    IF v_team IS NOT NULL THEN
        SELECT COALESCE(nickname, CONCAT('#', p_new_accid)) INTO v_nickname
        FROM accsys.accounts WHERE accid = p_new_accid LIMIT 1;

        INSERT INTO zgaming_web.mix_lobby_players
            (lobby_id, accid, nickname, team, is_captain, is_sub, connected_at)
        VALUES (p_lobby_id, p_new_accid, COALESCE(NULLIF(v_nickname, ''), CONCAT('#', p_new_accid)), v_team, 0, 1, NOW())
        ON DUPLICATE KEY UPDATE
            team = VALUES(team),
            is_sub = 1,
            connected_at = NOW();
    END IF;

    COMMIT;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`MixUpdateScore`$$
CREATE PROCEDURE `zgaming_web`.`MixUpdateScore`(
    IN p_lobby_id INT,
    IN p_score_a INT,
    IN p_score_b INT,
    IN p_half INT
)
BEGIN
    UPDATE zgaming_web.mix_lobbies
    SET score_a = p_score_a,
        score_b = p_score_b,
        half = p_half,
        started_at = COALESCE(started_at, NOW())
    WHERE id = p_lobby_id AND status = 'live';
END$$

-- ---------------------------------------------------------------------------
-- 1v1 de la web (servidor ARENA)
--
-- La arena no es como los servidores de MIX: corre varias series a la vez en
-- el mismo mapa, porque los rivales no se ven ni chocan entre si. Por eso el
-- 1v1 no usa MixClaimLobbyV2 (una sala por servidor) sino estos dos:
--   * Mix1v1Claim toma la siguiente serie lista, prefiriendo las del mapa que
--     ya esta puesto; solo agarra una de otro mapa si el servidor avisa que
--     puede cambiarlo (p_allow_map_change = 1, es decir, no hay ninguna serie
--     web en curso).
--   * Mix1v1GetSeries devuelve todas las series vivas del servidor con su
--     roster, para rearmarlas despues de un cambio de mapa o un reinicio.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `zgaming_web`.`Mix1v1Claim`$$
CREATE PROCEDURE `zgaming_web`.`Mix1v1Claim`(
    IN p_server_id INT,
    IN p_current_map VARCHAR(64),
    IN p_allow_map_change TINYINT
)
BEGIN
    DECLARE v_lobby_id INT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT id INTO v_lobby_id
    FROM zgaming_web.mix_lobbies
    WHERE status = 'ready'
      AND claimed_at IS NULL
      AND is_test = 0
      AND mode = '1v1'
      AND (map = p_current_map OR p_allow_map_change = 1)
    ORDER BY (map = p_current_map) DESC, id ASC
    LIMIT 1
    FOR UPDATE;

    IF v_lobby_id IS NOT NULL THEN
        UPDATE zgaming_web.mix_lobbies
        SET status = 'live',
            server_id = p_server_id,
            claimed_at = NOW(),
            heartbeat_at = NOW(),
            join_deadline = DATE_ADD(NOW(), INTERVAL 5 MINUTE)
        WHERE id = v_lobby_id AND claimed_at IS NULL;

        IF ROW_COUNT() = 0 THEN
            SET v_lobby_id = NULL;
        END IF;
    END IF;

    COMMIT;

    SELECT id, map, server_password, score_a, score_b, half, mode, 1 AS team_size
    FROM zgaming_web.mix_lobbies
    WHERE id = v_lobby_id;

    SELECT accid,
           CASE team WHEN 'A' THEN 1 WHEN 'B' THEN 2 ELSE 0 END AS team
    FROM zgaming_web.mix_lobby_players
    WHERE lobby_id = v_lobby_id
      AND team IS NOT NULL
      AND abandoned_at IS NULL
    ORDER BY team;
END$$

DROP PROCEDURE IF EXISTS `zgaming_web`.`Mix1v1GetSeries`$$
CREATE PROCEDURE `zgaming_web`.`Mix1v1GetSeries`(IN p_server_id INT)
BEGIN
    SELECT id, map, server_password, score_a, score_b, half
    FROM zgaming_web.mix_lobbies
    WHERE server_id = p_server_id
      AND mode = '1v1'
      AND status = 'live'
      AND is_test = 0
    ORDER BY id ASC;

    SELECT p.lobby_id, p.accid,
           CASE p.team WHEN 'A' THEN 1 WHEN 'B' THEN 2 ELSE 0 END AS team
    FROM zgaming_web.mix_lobby_players p
    JOIN zgaming_web.mix_lobbies l ON l.id = p.lobby_id
    WHERE l.server_id = p_server_id
      AND l.mode = '1v1'
      AND l.status = 'live'
      AND l.is_test = 0
      AND p.team IS NOT NULL
      AND p.abandoned_at IS NULL
    ORDER BY p.lobby_id, p.team;
END$$

DELIMITER ;
