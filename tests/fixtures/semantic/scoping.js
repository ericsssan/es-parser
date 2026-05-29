// Block scoping
{
    let x = 1;
    const y = 2;
    var z = 3; // hoisted to function/global
}
// x, y not accessible here; z is

// Function scoping
function outer() {
    var a = 1;
    let b = 2;

    function inner() {
        var c = 3;
        let d = 4;
        // a, b accessible (closure)
        return a + b + c + d;
    }

    // c, d not accessible here
    return inner();
}

// Nested blocks
function nested() {
    let x = 1;
    {
        let x = 2; // shadows outer x
        {
            let x = 3; // shadows again
        }
    }
}

// For loop scoping
for (let i = 0; i < 10; i++) {
    // i is scoped to the for block
}
// i not accessible here

for (var j = 0; j < 10; j++) {
    // j is hoisted to function/global
}
// j is accessible here
