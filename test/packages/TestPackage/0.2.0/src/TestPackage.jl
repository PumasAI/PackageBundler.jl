module TestPackage

import Example

greet() = print(Example.hello("0.2.0!"))

struct IntType
    i::Int
end

const INT_VALUE = IntType(42)

end # module TestPackage
