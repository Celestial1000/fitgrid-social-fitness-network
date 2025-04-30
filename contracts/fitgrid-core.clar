;; fitgrid-core
;; A smart contract that manages user profiles, connections, and the fitness reputation system
;; for the FitGrid social fitness network.

;; =========================================
;; Constants & Error Codes
;; =========================================

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u1001))
(define-constant ERR-USER-ALREADY-EXISTS (err u1002))
(define-constant ERR-USER-NOT-FOUND (err u1003))
(define-constant ERR-CONNECTION-EXISTS (err u1004))
(define-constant ERR-CONNECTION-NOT-FOUND (err u1005))
(define-constant ERR-GROUP-ALREADY-EXISTS (err u1006))
(define-constant ERR-GROUP-NOT-FOUND (err u1007))
(define-constant ERR-NOT-GROUP-MEMBER (err u1008))
(define-constant ERR-NOT-GROUP-ADMIN (err u1009))
(define-constant ERR-INVALID-POINTS (err u1010))
(define-constant ERR-ALREADY-ENDORSED (err u1011))
(define-constant ERR-CANNOT-ENDORSE-SELF (err u1012))
(define-constant ERR-INVALID-PRIVACY-SETTING (err u1013))

;; Privacy levels
(define-constant PRIVACY-PUBLIC u1)
(define-constant PRIVACY-CONNECTIONS-ONLY u2)
(define-constant PRIVACY-PRIVATE u3)

;; =========================================
;; Data Maps & Storage
;; =========================================

;; User profiles
(define-map users 
  { user-id: principal } 
  {
    username: (string-ascii 30),
    bio: (string-utf8 500),
    location: (string-ascii 100),
    preferred-activities: (list 10 (string-ascii 30)),
    fitness-goals: (list 5 (string-ascii 100)),
    achievements: (list 20 (string-ascii 100)),
    privacy-settings: {
      bio: uint,
      location: uint,
      activities: uint,
      goals: uint,
      achievements: uint
    },
    created-at: uint
  }
)

;; User fitness points
(define-map fitness-points
  { user-id: principal }
  { points: uint }
)

;; User connections (bidirectional)
(define-map connections
  { user-id: principal, connection-id: principal }
  { connected-at: uint, status: (string-ascii 20) } ;; status: "pending", "active", "blocked"
)

;; Connection endorsements (user-to-user)
(define-map endorsements
  { endorser: principal, endorsed: principal }
  { endorsed-at: uint, reason: (string-utf8 200) }
)

;; Fitness groups
(define-map fitness-groups
  { group-id: uint }
  {
    name: (string-ascii 50),
    description: (string-utf8 500),
    activity-type: (string-ascii 30),
    created-by: principal,
    admins: (list 5 principal),
    created-at: uint
  }
)

;; Group memberships
(define-map group-members
  { group-id: uint, member-id: principal }
  { joined-at: uint }
)

;; Group workouts/events
(define-map group-activities
  { activity-id: uint }
  {
    group-id: uint,
    name: (string-ascii 100),
    description: (string-utf8 500),
    scheduled-time: uint,
    created-by: principal,
    created-at: uint
  }
)

;; User activity log
(define-map activity-logs
  { log-id: uint }
  {
    user-id: principal,
    activity-type: (string-ascii 30),
    duration: uint,
    description: (string-utf8 500),
    verified-by: (optional principal),
    points-earned: uint,
    logged-at: uint
  }
)

;; Global counters
(define-data-var next-group-id uint u1)
(define-data-var next-activity-id uint u1)
(define-data-var next-log-id uint u1)

;; =========================================
;; Private Functions
;; =========================================

;; Check if a user exists
(define-private (user-exists (user-id principal))
  (is-some (map-get? users { user-id: user-id }))
)

;; Check if two users are connected
(define-private (are-connected (user-1 principal) (user-2 principal))
  (and
    (is-some (map-get? connections { user-id: user-1, connection-id: user-2 }))
    (is-some (map-get? connections { user-id: user-2, connection-id: user-1 }))
  )
)

;; Check if a user is a member of a group
(define-private (is-group-member (group-id uint) (user-id principal))
  (is-some (map-get? group-members { group-id: group-id, member-id: user-id }))
)

;; Check if a user is an admin of a group
(define-private (is-group-admin (group-id uint) (user-id principal))
  (let ((group-opt (map-get? fitness-groups { group-id: group-id })))
    (match group-opt
      group (fold-right (lambda (admin result) (or result (is-eq admin user-id))) false (get admins group))
      false
    )
  )
)

;; Add points to a user's fitness score
(define-private (add-points (user-id principal) (amount uint))
  (let ((current-points-data (default-to { points: u0 } (map-get? fitness-points { user-id: user-id }))))
    (map-set fitness-points
      { user-id: user-id }
      { points: (+ (get points current-points-data) amount) }
    )
  )
)

;; Check if the privacy setting allows visibility
;; Returns true if the data is visible to the requestor
(define-private (check-privacy-access 
  (owner principal) 
  (requestor principal) 
  (privacy-level uint))
  (or
    (is-eq owner requestor)                                ;; Owner can always see their own data
    (is-eq privacy-level PRIVACY-PUBLIC)                  ;; Public data is visible to everyone
    (and 
      (is-eq privacy-level PRIVACY-CONNECTIONS-ONLY)      ;; Connections-only visibility
      (are-connected owner requestor)
    )
  )
)

;; Get the next ID for a counter and increment it
(define-private (get-and-increment-id (counter-name (string-ascii 20)))
  (if (is-eq counter-name "group")
    (let ((id (var-get next-group-id)))
      (var-set next-group-id (+ id u1))
      id
    )
    (if (is-eq counter-name "activity")
      (let ((id (var-get next-activity-id)))
        (var-set next-activity-id (+ id u1))
        id
      )
      (let ((id (var-get next-log-id)))
        (var-set next-log-id (+ id u1))
        id
      )
    )
  )
)

;; =========================================
;; Read-Only Functions
;; =========================================

;; Get user profile (respects privacy settings)
(define-read-only (get-user-profile (user-id principal) (requestor principal))
  (let ((user-data-opt (map-get? users { user-id: user-id })))
    (match user-data-opt
      user-data
      (let ((privacy (get privacy-settings user-data)))
        (ok {
          username: (get username user-data),
          bio: (if (check-privacy-access user-id requestor (get bio privacy)) 
                (get bio user-data) 
                ""),
          location: (if (check-privacy-access user-id requestor (get location privacy)) 
                     (get location user-data) 
                     ""),
          preferred-activities: (if (check-privacy-access user-id requestor (get activities privacy)) 
                                 (get preferred-activities user-data) 
                                 (list)),
          fitness-goals: (if (check-privacy-access user-id requestor (get goals privacy)) 
                          (get fitness-goals user-data) 
                          (list)),
          achievements: (if (check-privacy-access user-id requestor (get achievements privacy)) 
                         (get achievements user-data) 
                         (list)),
          created-at: (get created-at user-data)
        }))
      ERR-USER-NOT-FOUND
    )
  )
)

;; Get user fitness points
(define-read-only (get-fitness-points (user-id principal))
  (let ((points-data (map-get? fitness-points { user-id: user-id })))
    (match points-data
      data (ok (get points data))
      (ok u0)
    )
  )
)

;; Get user connections
(define-read-only (get-user-connections (user-id principal))
  (ok (map-get? connections { user-id: user-id }))
)

;; Get group details
(define-read-only (get-group (group-id uint))
  (let ((group-data (map-get? fitness-groups { group-id: group-id })))
    (match group-data
      data (ok data)
      ERR-GROUP-NOT-FOUND
    )
  )
)

;; Check if a user has endorsed another user
(define-read-only (has-endorsed (endorser principal) (endorsed principal))
  (is-some (map-get? endorsements { endorser: endorser, endorsed: endorsed }))
)

;; =========================================
;; Public Functions
;; =========================================

;; Create a new user profile
(define-public (create-profile
  (username (string-ascii 30))
  (bio (string-utf8 500))
  (location (string-ascii 100))
  (preferred-activities (list 10 (string-ascii 30)))
  (fitness-goals (list 5 (string-ascii 100)))
)
  (let ((user-id tx-sender))
    (if (user-exists user-id)
      ERR-USER-ALREADY-EXISTS
      (begin
        (map-set users
          { user-id: user-id }
          {
            username: username,
            bio: bio,
            location: location,
            preferred-activities: preferred-activities,
            fitness-goals: fitness-goals,
            achievements: (list),
            privacy-settings: {
              bio: PRIVACY-PUBLIC,
              location: PRIVACY-PUBLIC,
              activities: PRIVACY-PUBLIC,
              goals: PRIVACY-PUBLIC,
              achievements: PRIVACY-PUBLIC
            },
            created-at: block-height
          }
        )
        ;; Initialize fitness points
        (map-set fitness-points
          { user-id: user-id }
          { points: u0 }
        )
        (ok true)
      )
    )
  )
)

;; Update user profile
(define-public (update-profile
  (bio (string-utf8 500))
  (location (string-ascii 100))
  (preferred-activities (list 10 (string-ascii 30)))
  (fitness-goals (list 5 (string-ascii 100)))
)
  (let ((user-id tx-sender)
        (user-data-opt (map-get? users { user-id: user-id })))
    (match user-data-opt
      user-data
      (begin
        (map-set users
          { user-id: user-id }
          (merge user-data {
            bio: bio,
            location: location,
            preferred-activities: preferred-activities,
            fitness-goals: fitness-goals
          })
        )
        (ok true)
      )
      ERR-USER-NOT-FOUND
    )
  )
)

;; Update privacy settings
(define-public (update-privacy-settings
  (bio-privacy uint)
  (location-privacy uint)
  (activities-privacy uint)
  (goals-privacy uint)
  (achievements-privacy uint)
)
  (let ((user-id tx-sender)
        (user-data-opt (map-get? users { user-id: user-id })))
    
    ;; Check that privacy levels are valid
    (asserts! (and 
                (or (is-eq bio-privacy PRIVACY-PUBLIC) 
                    (is-eq bio-privacy PRIVACY-CONNECTIONS-ONLY) 
                    (is-eq bio-privacy PRIVACY-PRIVATE))
                (or (is-eq location-privacy PRIVACY-PUBLIC) 
                    (is-eq location-privacy PRIVACY-CONNECTIONS-ONLY) 
                    (is-eq location-privacy PRIVACY-PRIVATE))
                (or (is-eq activities-privacy PRIVACY-PUBLIC) 
                    (is-eq activities-privacy PRIVACY-CONNECTIONS-ONLY) 
                    (is-eq activities-privacy PRIVACY-PRIVATE))
                (or (is-eq goals-privacy PRIVACY-PUBLIC) 
                    (is-eq goals-privacy PRIVACY-CONNECTIONS-ONLY) 
                    (is-eq goals-privacy PRIVACY-PRIVATE))
                (or (is-eq achievements-privacy PRIVACY-PUBLIC) 
                    (is-eq achievements-privacy PRIVACY-CONNECTIONS-ONLY) 
                    (is-eq achievements-privacy PRIVACY-PRIVATE))
              )
              ERR-INVALID-PRIVACY-SETTING)
    
    (match user-data-opt
      user-data
      (begin
        (map-set users
          { user-id: user-id }
          (merge user-data {
            privacy-settings: {
              bio: bio-privacy,
              location: location-privacy,
              activities: activities-privacy,
              goals: goals-privacy,
              achievements: achievements-privacy
            }
          })
        )
        (ok true)
      )
      ERR-USER-NOT-FOUND
    )
  )
)

;; Add achievement to user profile
(define-public (add-achievement (achievement (string-ascii 100)))
  (let ((user-id tx-sender)
        (user-data-opt (map-get? users { user-id: user-id })))
    (match user-data-opt
      user-data
      (begin
        (map-set users
          { user-id: user-id }
          (merge user-data {
            achievements: (unwrap-panic (as-max-len? 
                            (append (get achievements user-data) achievement)
                            u20))
          })
        )
        ;; Award points for achievement
        (add-points user-id u10)
        (ok true)
      )
      ERR-USER-NOT-FOUND
    )
  )
)

;; Request connection with another user
(define-public (request-connection (connection-id principal))
  (let ((user-id tx-sender))
    ;; Cannot connect with yourself
    (asserts! (not (is-eq user-id connection-id)) ERR-NOT-AUTHORIZED)
    
    ;; Check if connection already exists
    (asserts! (not (is-some (map-get? connections { user-id: user-id, connection-id: connection-id }))) 
              ERR-CONNECTION-EXISTS)
    
    ;; Check if both users exist
    (asserts! (user-exists user-id) ERR-USER-NOT-FOUND)
    (asserts! (user-exists connection-id) ERR-USER-NOT-FOUND)
    
    ;; Create connection request
    (map-set connections
      { user-id: user-id, connection-id: connection-id }
      { connected-at: block-height, status: "pending" }
    )
    
    (ok true)
  )
)

;; Accept connection request
(define-public (accept-connection (requestor principal))
  (let ((user-id tx-sender)
        (connection-opt (map-get? connections { user-id: requestor, connection-id: user-id })))
    
    ;; Check if request exists
    (asserts! (is-some connection-opt) ERR-CONNECTION-NOT-FOUND)
    
    ;; Create bidirectional connection
    (map-set connections
      { user-id: user-id, connection-id: requestor }
      { connected-at: block-height, status: "active" }
    )
    
    ;; Update requester's status
    (map-set connections
      { user-id: requestor, connection-id: user-id }
      { connected-at: block-height, status: "active" }
    )
    
    ;; Award small points for building network
    (add-points user-id u2)
    (add-points requestor u2)
    
    (ok true)
  )
)

;; Endorse another user
(define-public (endorse-user (user-id principal) (reason (string-utf8 200)))
  (let ((endorser tx-sender))
    ;; Cannot endorse yourself
    (asserts! (not (is-eq endorser user-id)) ERR-CANNOT-ENDORSE-SELF)
    
    ;; Check if both users exist
    (asserts! (user-exists endorser) ERR-USER-NOT-FOUND)
    (asserts! (user-exists user-id) ERR-USER-NOT-FOUND)
    
    ;; Check if they are connected
    (asserts! (are-connected endorser user-id) ERR-NOT-AUTHORIZED)
    
    ;; Check if already endorsed
    (asserts! (not (has-endorsed endorser user-id)) ERR-ALREADY-ENDORSED)
    
    ;; Create endorsement
    (map-set endorsements
      { endorser: endorser, endorsed: user-id }
      { endorsed-at: block-height, reason: reason }
    )
    
    ;; Award points to the endorsed user
    (add-points user-id u5)
    
    (ok true)
  )
)

;; Create a fitness group
(define-public (create-fitness-group 
  (name (string-ascii 50))
  (description (string-utf8 500))
  (activity-type (string-ascii 30))
)
  (let ((creator tx-sender)
        (group-id (get-and-increment-id "group")))
    
    ;; Create the group
    (map-set fitness-groups
      { group-id: group-id }
      {
        name: name,
        description: description,
        activity-type: activity-type,
        created-by: creator,
        admins: (list creator),
        created-at: block-height
      }
    )
    
    ;; Add creator as a member
    (map-set group-members
      { group-id: group-id, member-id: creator }
      { joined-at: block-height }
    )
    
    ;; Award points for creating a group
    (add-points creator u15)
    
    (ok group-id)
  )
)

;; Join a fitness group
(define-public (join-group (group-id uint))
  (let ((user-id tx-sender))
    ;; Check if group exists
    (asserts! (is-some (map-get? fitness-groups { group-id: group-id })) ERR-GROUP-NOT-FOUND)
    
    ;; Check if user is already a member
    (asserts! (not (is-group-member group-id user-id)) ERR-CONNECTION-EXISTS)
    
    ;; Add user to group
    (map-set group-members
      { group-id: group-id, member-id: user-id }
      { joined-at: block-height }
    )
    
    ;; Award points for joining a group
    (add-points user-id u5)
    
    (ok true)
  )
)

;; Create a group activity/workout
(define-public (create-group-activity
  (group-id uint)
  (name (string-ascii 100))
  (description (string-utf8 500))
  (scheduled-time uint)
)
  (let ((creator tx-sender)
        (activity-id (get-and-increment-id "activity")))
    
    ;; Check if group exists
    (asserts! (is-some (map-get? fitness-groups { group-id: group-id })) ERR-GROUP-NOT-FOUND)
    
    ;; Check if user is a member
    (asserts! (is-group-member group-id creator) ERR-NOT-GROUP-MEMBER)
    
    ;; Create the activity
    (map-set group-activities
      { activity-id: activity-id }
      {
        group-id: group-id,
        name: name,
        description: description,
        scheduled-time: scheduled-time,
        created-by: creator,
        created-at: block-height
      }
    )
    
    ;; Award points for organizing
    (add-points creator u8)
    
    (ok activity-id)
  )
)

;; Log a fitness activity
(define-public (log-activity
  (activity-type (string-ascii 30))
  (duration uint)
  (description (string-utf8 500))
)
  (let ((user-id tx-sender)
        (log-id (get-and-increment-id "log"))
        (points-earned (/ duration u10))) ;; 1 point per 10 units of duration
    
    ;; Create activity log
    (map-set activity-logs
      { log-id: log-id }
      {
        user-id: user-id,
        activity-type: activity-type,
        duration: duration,
        description: description,
        verified-by: none,
        points-earned: points-earned,
        logged-at: block-height
      }
    )
    
    ;; Award points for activity
    (add-points user-id points-earned)
    
    (ok log-id)
  )
)

;; Verify another user's activity (e.g., if you worked out together)
(define-public (verify-activity (log-id uint))
  (let ((verifier tx-sender)
        (log-opt (map-get? activity-logs { log-id: log-id })))
    
    (match log-opt
      log
      (let ((log-owner (get user-id log)))
        ;; Cannot verify own activity
        (asserts! (not (is-eq verifier log-owner)) ERR-NOT-AUTHORIZED)
        
        ;; Verify the activity
        (map-set activity-logs
          { log-id: log-id }
          (merge log { verified-by: (some verifier) })
        )
        
        ;; Award extra points for verified activity
        (add-points log-owner u5)
        
        ;; Award points to verifier
        (add-points verifier u2)
        
        (ok true)
      )
      ERR-USER-NOT-FOUND
    )
  )
)

;; Add admin to a group
(define-public (add-group-admin (group-id uint) (new-admin principal))
  (let ((caller tx-sender)
        (group-opt (map-get? fitness-groups { group-id: group-id })))
    
    (match group-opt
      group
      (begin
        ;; Check if caller is an admin
        (asserts! (is-group-admin group-id caller) ERR-NOT-GROUP-ADMIN)
        
        ;; Check if new admin is a member
        (asserts! (is-group-member group-id new-admin) ERR-NOT-GROUP-MEMBER)
        
        ;; Add new admin
        (map-set fitness-groups
          { group-id: group-id }
          (merge group {
            admins: (unwrap-panic (as-max-len? 
                      (append (get admins group) new-admin)
                      u5))
          })
        )
        
        (ok true)
      )
      ERR-GROUP-NOT-FOUND
    )
  )
)