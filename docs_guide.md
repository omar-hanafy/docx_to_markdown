# General Development & Documentation Philosophy

## Core Philosophy: "Describe the Behavior, Not Just the Data"

Code and documentation are not just labels; they are the manual for the machinery. A developer reading our code or docs should not only know *what* a component is, but *how* it changes the universe of the application.

**The Core Mantra:**
> "Don't tell me this is a function. Tell me what it changes, what happens if it fails, and why I should use it instead of the alternative."

---

## 1. The Three Layers of Great Communication

Every public API (Class, Function, Variable, Endpoint) should aim to satisfy three layers of understanding:

### Layer 1: The Definition (The "What")
*Basic. Required. Usually the first sentence.*
*   **Bad:** `/// The user list.`
*   **Good:** `/// The list of currently active users filtered by the selected organization.`

### Layer 2: The Context (The "When")
*Guidance. Helps the developer choose.*
*   **Bad:** `/// Connects to the database.`
*   **Good:** `/// Use this method for high-throughput batch operations. For single updates, prefer [updateUser] to maintain cache consistency.`

### Layer 3: The Interaction (The "How")
*The "Contract." Describes side effects, constraints, and relationships.*
*   **Bad:** `/// Returns the config.`
*   **Good:** `/// If the local config is missing, this fetches defaults from the remote server. Throws a [ConfigException] if network is unavailable.`

---

## 2. Guidelines for Code & Docs

### A. Connect the Dots (`[...]`)
Never force a developer to search for a related class or file. Use reference linking liberally.
*   **Rule:** If a function relies on a service, returns a specific model, or affects global state, link it.
*   **Example:** `/// See also: [FileHandler] for the underlying storage mechanism.`

### B. Define Constraints & Defaults
Ambiguity is the enemy of stability. Always answer:
1.  **Nullability:** What happens if input is null? (e.g., "Defaults to system theme").
2.  **Range:** What are the valid values? (e.g., "Must be non-negative").
3.  **State:** Does this trigger side effects? (e.g., "Writes to disk", "Rebuilds UI").

### C. The "Why" over The "What"
For complex logic, explain the motivation.
*   **Instead of:** `// Set retry count to 3.`
*   **Say:** `// Limit retries to 3 to prevent exponential backoff from locking the UI thread during outages.`

---

## 3. Practical Examples

### Example 1: A Configuration Property
**The Goal:** Documenting `timeout`.

*   ❌ **The "Lazy" Way:**
    ```dart
    /// The timeout duration.
    final Duration timeout;
    ```

*   ✅ **The "Behavior-First" Way:**
    ```dart
    /// The maximum duration to wait for a connection before aborting.
    ///
    /// If this limit is exceeded, a [TimeoutException] is thrown and the
    /// request is cancelled to free up resources.
    ///
    /// Defaults to 30 seconds if not specified in [NetworkConfig].
    final Duration timeout;
    ```

### Example 2: A Service Class
**The Goal:** Documenting `AuthService`.

*   ❌ **The "Lazy" Way:**
    ```dart
    /// Handles authentication.
    class AuthService ...
    ```

*   ✅ **The "Behavior-First" Way:**
    ```dart
    /// Manages the user authentication lifecycle and token persistence.
    ///
    /// [AuthService] handles login, token refresh, and secure storage of credentials.
    /// It broadcasts changes via [authStateChanges] so the UI can redirect automatically.
    ///
    /// ### Usage
    /// * Call [signIn] to start a session.
    /// * Listen to [user] to react to session changes.
    /// * Data is persisted using [SecureStorage].
    class AuthService ...
    ```

---

## 4. Private Code Philosophy

We apply the same rigor to private (`_`) implementation details when the logic is complex. Future maintainers (including yourself) need to know the *story* of the implementation.

*   **Don't comment:** `// Loop through items.`
*   **Do comment:** `// We iterate in reverse order here to safely remove items without invalidating the index.`

---

## 5. The Checklist

Before finishing a task or merging code, ask:
1.  [ ] Does the name/doc explain the "What"?
2.  [ ] Did I explain edge cases (nulls, errors, empty states)?
3.  [ ] Did I mention interactions with other parts of the system?
4.  [ ] Are related components linked or referenced?
5.  [ ] Is the "Why" clear for any non-standard logic?

---

*This document serves as the source of truth for our development philosophy.*