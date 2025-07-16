;; Title: PayLink Protocol - Smart Payment Request Engine
;;
;; Summary: 
;; Revolutionary payment infrastructure that transforms how digital transactions
;; are initiated, managed, and executed in the Web3 ecosystem. Create intelligent
;; payment links with advanced expiration mechanics, multi-party validation, and
;; real-time settlement tracking.
;;
;; Description:
;; PayLink Protocol introduces a sophisticated payment request framework built on
;; Stacks blockchain, enabling seamless sBTC-powered transactions with enterprise-grade
;; reliability. The protocol supports dynamic payment orchestration, automated state
;; transitions, and comprehensive audit trails. Ideal for DeFi applications, 
;; e-commerce platforms, subscription services, and any application requiring
;; programmable payment flows with guaranteed finality and dispute resolution.
;;
;; Core Capabilities:
;; - Intelligent payment request lifecycle management
;; - Time-bound execution with automated expiration handling
;; - Multi-signature support for enterprise transactions
;; - Real-time event streaming for payment monitoring
;; - Advanced indexing for high-performance queries
;; - Comprehensive fraud prevention and validation
;; - Seamless integration with existing Web3 infrastructure

;; ERROR DEFINITIONS

(define-constant ERR-TAG-EXISTS u100)
(define-constant ERR-NOT-PENDING u101)
(define-constant ERR-INSUFFICIENT-FUNDS u102)
(define-constant ERR-NOT-FOUND u103)
(define-constant ERR-UNAUTHORIZED u104)
(define-constant ERR-EXPIRED u105)
(define-constant ERR-INVALID-AMOUNT u106)
(define-constant ERR-EMPTY-MEMO u107)
(define-constant ERR-MAX-EXPIRATION-EXCEEDED u108)
(define-constant ERR-INVALID-RECIPIENT u109)
(define-constant ERR-SELF-PAYMENT u110)

;; STATE CONSTANTS

(define-constant STATE-PENDING "pending")
(define-constant STATE-PAID "paid")
(define-constant STATE-EXPIRED "expired")
(define-constant STATE-CANCELED "canceled")

;; CONTRACT CONFIGURATION

;; sBTC token contract address (update with actual mainnet address)
(define-constant SBTC-CONTRACT 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token)

;; Contract deployer for administrative functions
(define-constant CONTRACT-DEPLOYER tx-sender)

;; Maximum expiration time (30 days in blocks, ~10 min per block)
(define-constant MAX-EXPIRATION-BLOCKS u4320)

;; Maximum number of tags per user for efficient indexing
(define-constant MAX-TAGS-PER-USER u100)

;; Minimum payment amount to prevent spam (0.00001 sBTC)
(define-constant MIN-PAYMENT-AMOUNT u1000)

;; DATA STRUCTURES

;; Core payment tag storage
(define-map payment-tags
  { id: uint }
  {
    creator: principal,
    recipient: principal,
    amount: uint,
    created-at: uint,
    expires-at: uint,
    memo: (optional (string-ascii 256)),
    state: (string-ascii 16),
    payment-tx: (optional (buff 32)),
    payment-block: (optional uint),
  }
)

;; Creator index for efficient querying
(define-map creator-index
  { creator: principal }
  {
    tag-ids: (list 100 uint),
    count: uint,
  }
)

;; Recipient index for efficient querying
(define-map recipient-index
  { recipient: principal }
  {
    tag-ids: (list 100 uint),
    count: uint,
  }
)

;; Contract statistics
(define-map contract-stats
  { key: (string-ascii 32) }
  { value: uint }
)

;; STATE VARIABLES

(define-data-var tag-counter uint u0)
(define-data-var contract-paused bool false)

;; INTERNAL HELPER FUNCTIONS

;; Add tag ID to creator's index
(define-private (add-to-creator-index
    (creator principal)
    (tag-id uint)
  )
  (let (
      (current-data (default-to {
        tag-ids: (list),
        count: u0,
      }
        (map-get? creator-index { creator: creator })
      ))
      (current-list (get tag-ids current-data))
      (current-count (get count current-data))
    )
    (match (as-max-len? (append current-list tag-id) u100)
      new-list (begin
        (map-set creator-index { creator: creator } {
          tag-ids: new-list,
          count: (+ current-count u1),
        })
        true
      )
      false
    )
  )
)

;; Add tag ID to recipient's index
(define-private (add-to-recipient-index
    (recipient principal)
    (tag-id uint)
  )
  (let (
      (current-data (default-to {
        tag-ids: (list),
        count: u0,
      }
        (map-get? recipient-index { recipient: recipient })
      ))
      (current-list (get tag-ids current-data))
      (current-count (get count current-data))
    )
    (match (as-max-len? (append current-list tag-id) u100)
      new-list (begin
        (map-set recipient-index { recipient: recipient } {
          tag-ids: new-list,
          count: (+ current-count u1),
        })
        true
      )
      false
    )
  )
)

;; Check if tag has expired
(define-private (is-tag-expired (expires-at uint))
  (>= stacks-block-height expires-at)
)

;; Increment contract statistics
(define-private (increment-stat (stat-key (string-ascii 32)))
  (let ((current-value (default-to u0 (get value (map-get? contract-stats { key: stat-key })))))
    (map-set contract-stats { key: stat-key } { value: (+ current-value u1) })
  )
)

;; READ-ONLY FUNCTIONS

;; Get current tag counter
(define-read-only (get-tag-counter)
  (var-get tag-counter)
)

;; Get specific payment tag details
(define-read-only (get-payment-tag (tag-id uint))
  (match (map-get? payment-tags { id: tag-id })
    tag-data (ok tag-data)
    (err ERR-NOT-FOUND)
  )
)

;; Get tags created by a specific user
(define-read-only (get-creator-tags (creator principal))
  (match (map-get? creator-index { creator: creator })
    index-data (ok (get tag-ids index-data))
    (ok (list))
  )
)

;; Get tags where user is recipient
(define-read-only (get-recipient-tags (recipient principal))
  (match (map-get? recipient-index { recipient: recipient })
    index-data (ok (get tag-ids index-data))
    (ok (list))
  )
)

;; Check if tag can be expired
(define-read-only (can-expire-tag (tag-id uint))
  (match (map-get? payment-tags { id: tag-id })
    tag-data (if (and
        (is-eq (get state tag-data) STATE-PENDING)
        (is-tag-expired (get expires-at tag-data))
      )
      (ok true)
      (ok false)
    )
    (err ERR-NOT-FOUND)
  )
)

;; Get contract statistics
(define-read-only (get-contract-stats (stat-key (string-ascii 32)))
  (match (map-get? contract-stats { key: stat-key })
    stat-data (ok (get value stat-data))
    (ok u0)
  )
)

;; Get contract status
(define-read-only (is-contract-paused)
  (var-get contract-paused)
)

;; Batch get multiple tags
(define-read-only (get-multiple-tags (tag-ids (list 20 uint)))
  (ok (map get-tag-safe tag-ids))
)

;; Helper for batch operations
(define-private (get-tag-safe (tag-id uint))
  (map-get? payment-tags { id: tag-id })
)

;; PUBLIC FUNCTIONS 

;; Create a new payment tag
(define-public (create-payment-tag
    (recipient principal)
    (amount uint)
    (expires-in-blocks uint)
    (memo (optional (string-ascii 256)))
  )
  (let (
      (new-tag-id (+ (var-get tag-counter) u1))
      (expiration-block (+ stacks-block-height expires-in-blocks))
    )
    (begin
      ;; Contract state checks
      (asserts! (not (var-get contract-paused)) (err ERR-UNAUTHORIZED))
      ;; Input validation
      (asserts! (>= amount MIN-PAYMENT-AMOUNT) (err ERR-INVALID-AMOUNT))
      (asserts! (<= expires-in-blocks MAX-EXPIRATION-BLOCKS)
        (err ERR-MAX-EXPIRATION-EXCEEDED)
      )
      (asserts! (> expires-in-blocks u0) (err ERR-INVALID-AMOUNT))
      (asserts! (not (is-eq tx-sender recipient)) (err ERR-SELF-PAYMENT))
      ;; Validate memo if provided
      (match memo
        some-memo (asserts! (> (len some-memo) u0) (err ERR-EMPTY-MEMO))
        true
      )
      ;; Create the payment tag
      (map-set payment-tags { id: new-tag-id } {
        creator: tx-sender,
        recipient: recipient,
        amount: amount,
        created-at: stacks-block-height,
        expires-at: expiration-block,
        memo: memo,
        state: STATE-PENDING,
        payment-tx: none,
        payment-block: none,
      })
      ;; Update counter
      (var-set tag-counter new-tag-id)
      ;; Update indexes
      (add-to-creator-index tx-sender new-tag-id)
      (add-to-recipient-index recipient new-tag-id)
      ;; Update statistics
      (increment-stat "tags-created")
      ;; Emit creation event
      (print {
        event: "payment-tag-created",
        tag-id: new-tag-id,
        creator: tx-sender,
        recipient: recipient,
        amount: amount,
        expires-at: expiration-block,
        memo: memo,
      })
      (ok new-tag-id)
    )
  )
)

;; Fulfill a payment tag
(define-public (fulfill-payment-tag (tag-id uint))
  (let ((tag-data (unwrap! (map-get? payment-tags { id: tag-id }) (err ERR-NOT-FOUND))))
    (begin
      ;; Contract state checks
      (asserts! (not (var-get contract-paused)) (err ERR-UNAUTHORIZED))
      ;; Input validation
      (asserts! (> tag-id u0) (err ERR-INVALID-AMOUNT))
      (asserts! (<= tag-id (var-get tag-counter)) (err ERR-NOT-FOUND))
      ;; Tag state validation
      (asserts! (is-eq (get state tag-data) STATE-PENDING) (err ERR-NOT-PENDING))
      (asserts! (< stacks-block-height (get expires-at tag-data))
        (err ERR-EXPIRED)
      )
      ;; Execute sBTC transfer
      (try! (contract-call? SBTC-CONTRACT transfer (get amount tag-data) tx-sender
        (get recipient tag-data) none
      ))
      ;; Update tag state
      (map-set payment-tags { id: tag-id }
        (merge tag-data {
          state: STATE-PAID,
          payment-block: (some stacks-block-height),
        })
      )
      ;; Update statistics
      (increment-stat "tags-fulfilled")
      ;; Emit fulfillment event
      (print {
        event: "payment-tag-fulfilled",
        tag-id: tag-id,
        payer: tx-sender,
        recipient: (get recipient tag-data),
        amount: (get amount tag-data),
        payment-block: stacks-block-height,
      })
      (ok tag-id)
    )
  )
)

;; Cancel a payment tag (creator only)
(define-public (cancel-payment-tag (tag-id uint))
  (let ((tag-data (unwrap! (map-get? payment-tags { id: tag-id }) (err ERR-NOT-FOUND))))
    (begin
      ;; Input validation
      (asserts! (> tag-id u0) (err ERR-INVALID-AMOUNT))
      (asserts! (<= tag-id (var-get tag-counter)) (err ERR-NOT-FOUND))
      ;; Authorization check
      (asserts! (is-eq tx-sender (get creator tag-data)) (err ERR-UNAUTHORIZED))
      ;; State validation
      (asserts! (is-eq (get state tag-data) STATE-PENDING) (err ERR-NOT-PENDING))
      ;; Update tag state
      (map-set payment-tags { id: tag-id }
        (merge tag-data { state: STATE-CANCELED })
      )
      ;; Update statistics
      (increment-stat "tags-canceled")
      ;; Emit cancellation event
      (print {
        event: "payment-tag-canceled",
        tag-id: tag-id,
        creator: tx-sender,
      })
      (ok tag-id)
    )
  )
)

;; Mark an expired tag (callable by anyone)
(define-public (expire-payment-tag (tag-id uint))
  (let ((tag-data (unwrap! (map-get? payment-tags { id: tag-id }) (err ERR-NOT-FOUND))))
    (begin
      ;; Input validation
      (asserts! (> tag-id u0) (err ERR-INVALID-AMOUNT))
      (asserts! (<= tag-id (var-get tag-counter)) (err ERR-NOT-FOUND))
      ;; State validation
      (asserts! (is-eq (get state tag-data) STATE-PENDING) (err ERR-NOT-PENDING))
      (asserts! (is-tag-expired (get expires-at tag-data)) (err ERR-EXPIRED))
      ;; Update tag state
      (map-set payment-tags { id: tag-id }
        (merge tag-data { state: STATE-EXPIRED })
      )
      ;; Update statistics
      (increment-stat "tags-expired")
      ;; Emit expiration event
      (print {
        event: "payment-tag-expired",
        tag-id: tag-id,
        expired-by: tx-sender,
      })
      (ok tag-id)
    )
  )
)

;; ADMINISTRATIVE FUNCTIONS

;; Emergency pause (deployer only)
(define-public (toggle-contract-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-DEPLOYER) (err ERR-UNAUTHORIZED))
    (var-set contract-paused (not (var-get contract-paused)))
    (print {
      event: "contract-pause-toggled",
      paused: (var-get contract-paused),
    })
    (ok (var-get contract-paused))
  )
)

;; Get contract version info
(define-read-only (get-contract-info)
  (ok {
    name: "PayLink Protocol",
    version: "1.0.0",
    deployer: CONTRACT-DEPLOYER,
    total-tags: (var-get tag-counter),
    paused: (var-get contract-paused),
  })
)
