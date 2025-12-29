package bitbarrel

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

// WebSocket represents a WebSocket connection
type WebSocket struct {
	conn     net.Conn
	reader   *bufio.Reader
	isClient bool
}

// WSMessageType represents a WebSocket message type
type WSMessageType int

const (
	// Text message type (not used in BitBarrel)
	TextMessage WSMessageType = 1
	// Binary message type
	BinaryMessage WSMessageType = 2
	// Close message type
	CloseMessage WSMessageType = 8
)

// WebSocket frame opcodes
const (
	wsContinuationFrame = 0x0
	wsTextFrame         = 0x1
	wsBinaryFrame       = 0x2
	wsCloseFrame        = 0x8
	wsPingFrame         = 0x9
	wsPongFrame         = 0xA
)

// Dial connects to a WebSocket server
func Dial(address string) (*WebSocket, error) {
	// Parse the address
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, fmt.Errorf("invalid address: %w", err)
	}

	// Connect to the server
	conn, err := net.Dial("tcp", net.JoinHostPort(host, port))
	if err != nil {
		return nil, fmt.Errorf("failed to connect: %w", err)
	}

	// Generate WebSocket key
	key := make([]byte, 16)
	if _, err := rand.Read(key); err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to generate key: %w", err)
	}
	wsKey := base64.StdEncoding.EncodeToString(key)

	// Build handshake request
	handshake := fmt.Sprintf(
		"GET /ws HTTP/1.1\r\n"+
			"Host: %s:%s\r\n"+
			"Upgrade: websocket\r\n"+
			"Connection: Upgrade\r\n"+
			"Sec-WebSocket-Key: %s\r\n"+
			"Sec-WebSocket-Version: 13\r\n"+
			"\r\n",
		host, port, wsKey,
	)

	// Send handshake
	if _, err := conn.Write([]byte(handshake)); err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to send handshake: %w", err)
	}

	// Read response
	reader := bufio.NewReader(conn)
	resp, err := reader.ReadString('\n')
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	// Check response
	if !strings.Contains(resp, "101 Switching Protocols") {
		conn.Close()
		return nil, errors.New("websocket handshake failed")
	}

	// Read headers
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			conn.Close()
			return nil, fmt.Errorf("failed to read headers: %w", err)
		}
		if line == "\r\n" {
			break
		}
	}

	return &WebSocket{
		conn:     conn,
		reader:   reader,
		isClient: true,
	}, nil
}

// DialWithHeaders connects to a WebSocket server with custom headers
func DialWithHeaders(address string, headers map[string]string) (*WebSocket, error) {
	// Parse the address
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, fmt.Errorf("invalid address: %w", err)
	}

	// Connect to the server
	conn, err := net.Dial("tcp", net.JoinHostPort(host, port))
	if err != nil {
		return nil, fmt.Errorf("failed to connect: %w", err)
	}

	// Generate WebSocket key
	key := make([]byte, 16)
	if _, err := rand.Read(key); err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to generate key: %w", err)
	}
	wsKey := base64.StdEncoding.EncodeToString(key)

	// Build handshake request with custom headers
	handshake := fmt.Sprintf(
		"GET /ws HTTP/1.1\r\n"+
			"Host: %s:%s\r\n"+
			"Upgrade: websocket\r\n"+
			"Connection: Upgrade\r\n"+
			"Sec-WebSocket-Key: %s\r\n"+
			"Sec-WebSocket-Version: 13\r\n",
		host, port, wsKey,
	)

	// Add custom headers
	for key, value := range headers {
		handshake += fmt.Sprintf("%s: %s\r\n", key, value)
	}

	// Add empty line to end headers
	handshake += "\r\n"

	// Send handshake
	if _, err := conn.Write([]byte(handshake)); err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to send handshake: %w", err)
	}

	// Read and parse response
	reader := bufio.NewReader(conn)

	// Read status line
	statusLine, err := reader.ReadString('\n')
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to read status: %w", err)
	}

	// Check status
	if !contains(statusLine, "101 Switching Protocols") {
		conn.Close()
		return nil, fmt.Errorf("unexpected status: %s", strings.TrimSpace(statusLine))
	}

	// Read headers
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			conn.Close()
			return nil, fmt.Errorf("failed to read headers: %w", err)
		}
		if line == "\r\n" {
			break
		}
	}

	return &WebSocket{
		conn:     conn,
		reader:   reader,
		isClient: true,
	}, nil
}

// Close closes the WebSocket connection
func (ws *WebSocket) Close() error {
	if ws.conn == nil {
		return nil
	}

	// Send close frame
	closeFrame := []byte{0x88, 0x00} // FIN + close opcode, no payload
	ws.conn.Write(closeFrame)

	return ws.conn.Close()
}

// WriteMessage writes a message to the WebSocket
func (ws *WebSocket) WriteMessage(messageType WSMessageType, data []byte) error {
	if ws.conn == nil {
		return errors.New("connection closed")
	}

	// Prepare frame header
	frame := make([]byte, 0, len(data)+14)

	// First byte: FIN + opcode
	var opcode byte
	switch messageType {
	case TextMessage:
		opcode = wsTextFrame
	case BinaryMessage:
		opcode = wsBinaryFrame
	case CloseMessage:
		opcode = wsCloseFrame
	default:
		return errors.New("unsupported message type")
	}
	frame = append(frame, 0x80|opcode) // FIN bit set

	// Mask bit and payload length
	maskBit := byte(0x00)
	if ws.isClient {
		maskBit = 0x80
	}

	payloadLen := len(data)
	if payloadLen < 126 {
		frame = append(frame, maskBit|byte(payloadLen))
	} else if payloadLen < 65536 {
		frame = append(frame, maskBit|126)
		lenBytes := make([]byte, 2)
		binary.BigEndian.PutUint16(lenBytes, uint16(payloadLen))
		frame = append(frame, lenBytes...)
	} else {
		frame = append(frame, maskBit|127)
		lenBytes := make([]byte, 8)
		binary.BigEndian.PutUint64(lenBytes, uint64(payloadLen))
		frame = append(frame, lenBytes...)
	}

	// Masking key (client only)
	var maskKey [4]byte
	if ws.isClient {
		if _, err := rand.Read(maskKey[:]); err != nil {
			return fmt.Errorf("failed to generate mask: %w", err)
		}
		frame = append(frame, maskKey[:]...)
	}

	// Payload
	payload := data
	if ws.isClient {
		// Apply mask
		masked := make([]byte, len(data))
		for i := range data {
			masked[i] = data[i] ^ maskKey[i%4]
		}
		payload = masked
	}
	frame = append(frame, payload...)

	// Write frame
	if _, err := ws.conn.Write(frame); err != nil {
		return fmt.Errorf("failed to write frame: %w", err)
	}

	return nil
}

// ReadMessage reads a message from the WebSocket
func (ws *WebSocket) ReadMessage() (WSMessageType, []byte, error) {
	if ws.conn == nil {
		return 0, nil, errors.New("connection closed")
	}

	// Read first two bytes
	header := make([]byte, 2)
	if _, err := io.ReadFull(ws.reader, header); err != nil {
		return 0, nil, fmt.Errorf("failed to read header: %w", err)
	}

	// Parse FIN and opcode
	fin := (header[0] & 0x80) != 0
	opcode := header[0] & 0x0F

	if !fin {
		return 0, nil, errors.New("fragmented frames not supported")
	}

	// Parse mask and payload length
	masked := (header[1] & 0x80) != 0
	payloadLen := int(header[1] & 0x7F)

	// Extended payload length
	if payloadLen == 126 {
		lenBytes := make([]byte, 2)
		if _, err := io.ReadFull(ws.reader, lenBytes); err != nil {
			return 0, nil, fmt.Errorf("failed to read length: %w", err)
		}
		payloadLen = int(binary.BigEndian.Uint16(lenBytes))
	} else if payloadLen == 127 {
		return 0, nil, errors.New("64-bit length not supported")
	}

	// Read masking key if present
	var maskKey [4]byte
	if masked {
		if _, err := io.ReadFull(ws.reader, maskKey[:]); err != nil {
			return 0, nil, fmt.Errorf("failed to read mask: %w", err)
		}
	}

	// Read payload
	payload := make([]byte, payloadLen)
	if _, err := io.ReadFull(ws.reader, payload); err != nil {
		return 0, nil, fmt.Errorf("failed to read payload: %w", err)
	}

	// Unmask if necessary
	if masked {
		for i := range payload {
			payload[i] = payload[i] ^ maskKey[i%4]
		}
	}

	// Determine message type
	var msgType WSMessageType
	switch opcode {
	case wsTextFrame:
		msgType = TextMessage
	case wsBinaryFrame:
		msgType = BinaryMessage
	case wsCloseFrame:
		msgType = CloseMessage
	default:
		return 0, nil, fmt.Errorf("unsupported opcode: %d", opcode)
	}

	return msgType, payload, nil
}

// SetDeadline sets the read and write deadlines
func (ws *WebSocket) SetDeadline(t time.Time) error {
	return ws.conn.SetDeadline(t)
}

// SetReadDeadline sets the read deadline
func (ws *WebSocket) SetReadDeadline(t time.Time) error {
	return ws.conn.SetReadDeadline(t)
}

// SetWriteDeadline sets the write deadline
func (ws *WebSocket) SetWriteDeadline(t time.Time) error {
	return ws.conn.SetWriteDeadline(t)
}
