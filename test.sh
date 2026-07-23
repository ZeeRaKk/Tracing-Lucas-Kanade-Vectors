// Cargo.toml : serialport = "4"
use std::time::Duration;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut port = serialport::new("/dev/ttyUSB4", 115200)
        .data_bits(serialport::DataBits::Eight)
        .parity(serialport::Parity::None)   // Even si c'est du Modbus RTU
        .stop_bits(serialport::StopBits::One)
        .timeout(Duration::from_millis(1000))
        .open()?;

    port.clear(serialport::ClearBuffer::All)?;

    const CMD: [u8; 9] = [0x00, 0x01, 0x00, 0x20, 0x00, 0x00, 0x04, 0x3D, 0xD2];
    port.write_all(&CMD)?;
    port.flush()?;

    let mut buf = Vec::new();
    let mut chunk = [0u8; 256];
    loop {
        match port.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => break,
            Err(e) => return Err(e.into()),
        }
    }
    println!("{:02X?}", buf);
    Ok(())
}