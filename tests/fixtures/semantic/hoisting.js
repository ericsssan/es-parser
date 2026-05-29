// var hoisting
console.log(x); // undefined (not ReferenceError)
var x = 5;

// function declaration hoisting
greet(); // works — function declarations are fully hoisted
function greet() {
    return "hello";
}

// let/const TDZ (Temporal Dead Zone)
// console.log(y); // would be ReferenceError
let y = 10;

// Function declaration in block (sloppy mode)
{
    function blockFn() { return 1; }
}
// blockFn may or may not be accessible depending on strict mode

// var in for loop hoists
function forHoist() {
    for (var i = 0; i < 3; i++) {
        // i is hoisted
    }
    return i; // 3 — accessible because var hoists
}

// Hoisting across nested blocks
function complexHoist() {
    {
        {
            var deep = 42; // hoists to function scope
        }
    }
    return deep; // 42
}
