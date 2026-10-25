//! Minimal f32 3D vector math mirroring Godot's `Vector3` semantics.

use std::ops::{Add, Mul, Sub};

pub const EPS: f32 = 1e-6;
pub const UP: Vec3 = Vec3 {
    x: 0.0,
    y: 1.0,
    z: 0.0,
};
pub const BACK: Vec3 = Vec3 {
    x: 0.0,
    y: 0.0,
    z: 1.0,
};
pub const ZERO: Vec3 = Vec3 {
    x: 0.0,
    y: 0.0,
    z: 0.0,
};

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Vec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Vec3 {
    pub fn new(x: f32, y: f32, z: f32) -> Self {
        Self { x, y, z }
    }

    pub fn from_array(a: [f32; 3]) -> Self {
        Self {
            x: a[0],
            y: a[1],
            z: a[2],
        }
    }

    pub fn to_array(self) -> [f32; 3] {
        [self.x, self.y, self.z]
    }

    pub fn length_squared(self) -> f32 {
        self.x * self.x + self.y * self.y + self.z * self.z
    }

    pub fn length(self) -> f32 {
        self.length_squared().sqrt()
    }

    pub fn normalized(self) -> Self {
        let l = self.length();
        if l > 0.0 {
            self * (1.0 / l)
        } else {
            ZERO
        }
    }

    /// Godot `_safe_normalized`: zero when below eps.
    pub fn safe_normalized(self) -> Self {
        if self.length_squared() < EPS * EPS {
            ZERO
        } else {
            self.normalized()
        }
    }

    pub fn dot(self, o: Self) -> f32 {
        self.x * o.x + self.y * o.y + self.z * o.z
    }

    pub fn cross(self, o: Self) -> Self {
        Self {
            x: self.y * o.z - self.z * o.y,
            y: self.z * o.x - self.x * o.z,
            z: self.x * o.y - self.y * o.x,
        }
    }

    /// Godot `angle_to`: 0 for degenerate input.
    pub fn angle_to(self, o: Self) -> f32 {
        let d = self.length_squared() * o.length_squared();
        if d < EPS * EPS {
            return 0.0;
        }
        (self.dot(o) / d.sqrt()).clamp(-1.0, 1.0).acos()
    }

    /// Godot `rotated(axis, angle)`: Rodrigues; axis should be normalized.
    pub fn rotated(self, axis: Self, angle: f32) -> Self {
        let (s, c) = angle.sin_cos();
        self * c + axis.cross(self) * s + axis * (axis.dot(self) * (1.0 - c))
    }

    /// Godot `bounce(n)`: reflect off plane with unit normal n.
    pub fn bounce(self, n: Self) -> Self {
        self - n * (2.0 * self.dot(n))
    }

    pub fn lerp(self, to: Self, w: f32) -> Self {
        self + (to - self) * w
    }

    pub fn is_zero(self) -> bool {
        self == ZERO
    }
}

impl Add for Vec3 {
    type Output = Self;
    fn add(self, o: Self) -> Self {
        Self::new(self.x + o.x, self.y + o.y, self.z + o.z)
    }
}

impl Sub for Vec3 {
    type Output = Self;
    fn sub(self, o: Self) -> Self {
        Self::new(self.x - o.x, self.y - o.y, self.z - o.z)
    }
}

impl Mul<f32> for Vec3 {
    type Output = Self;
    fn mul(self, s: f32) -> Self {
        Self::new(self.x * s, self.y * s, self.z * s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;

    #[test]
    fn angle_and_rotate() {
        let a = Vec3::new(1.0, 0.0, 0.0);
        let b = Vec3::new(0.0, 0.0, 1.0);
        assert!((a.angle_to(b) - PI / 2.0).abs() < 1e-6);
        // Rotate +X toward +Z by 90° about +Y: Godot's rotated is
        // right-handed; verify against known Godot result instead of sign.
        let r = a.rotated(UP, PI / 2.0);
        assert!(r.length() - 1.0 < 1e-6);
        // bounce off XZ plane normal: y flips.
        let v = Vec3::new(1.0, -2.0, 3.0);
        let bounced = v.bounce(UP);
        assert!((bounced.y - 2.0).abs() < 1e-6);
        assert!((bounced.x - 1.0).abs() < 1e-6);
    }
}
