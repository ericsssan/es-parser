// Basic closure
function makeCounter() {
    let count = 0;
    return function() {
        count++;
        return count;
    };
}

// Closure over loop variable (let)
function makeCallbacks() {
    const callbacks = [];
    for (let i = 0; i < 5; i++) {
        callbacks.push(() => i); // each captures its own i
    }
    return callbacks;
}

// Closure over loop variable (var) — classic bug
function makeCallbacksBuggy() {
    const callbacks = [];
    for (var i = 0; i < 5; i++) {
        callbacks.push(() => i); // all capture the same i
    }
    return callbacks;
}

// Nested closures
function outer() {
    let a = 1;
    function middle() {
        let b = 2;
        function inner() {
            return a + b; // captures from both outer scopes
        }
        return inner;
    }
    return middle;
}

// IIFE (Immediately Invoked Function Expression)
const result = (function() {
    let private = 42;
    return { get: () => private };
})();
