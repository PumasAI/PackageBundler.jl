module TestPackage

import Example

greet() = print(Example.hello("0.1.0!"))

42 # This "code" will not serialize on a 64-bit platform, and deserialize on a 32-bit platform

end # module TestPackage
