"""Protocol-level tests for BitBarrel Python client."""

import pytest
import struct
from bitbarrel.protocol import (
    Command, Status, ProtocolError,
    encode_request, decode_request,
    encode_response, decode_response,
    MAX_KEY_SIZE, MAX_VALUE_SIZE
)


class TestCommandEnum:
    """Test Command enum values."""

    def test_command_values(self):
        """Test that all command values are correct."""
        assert Command.GET == 0x01
        assert Command.SET == 0x02
        assert Command.DELETE == 0x03
        assert Command.EXISTS == 0x04
        assert Command.COUNT == 0x05
        assert Command.LIST_KEYS == 0x06
        assert Command.PING == 0x09
        assert Command.TRAVERSE == 0x20
        assert Command.RANGE_QUERY == 0x21
        assert Command.PREFIX_QUERY == 0x22
        assert Command.RANGE_COUNT == 0x23
        assert Command.CREATE_BARREL == 0x10
        assert Command.OPEN_BARREL == 0x11
        assert Command.USE_BARREL == 0x12
        assert Command.CLOSE_BARREL == 0x13
        assert Command.LIST_BARRELS == 0x14
        assert Command.DROP_BARREL == 0x15
        assert Command.GET_BARREL_CONFIG == 0x16
        assert Command.SET_BARREL_CONFIG == 0x17

    def test_all_commands_unique(self):
        """Test that all command values are unique."""
        commands = [
            Command.GET, Command.SET, Command.DELETE, Command.EXISTS,
            Command.COUNT, Command.LIST_KEYS, Command.PING, Command.TRAVERSE,
            Command.RANGE_QUERY, Command.PREFIX_QUERY, Command.RANGE_COUNT,
            Command.CREATE_BARREL, Command.OPEN_BARREL, Command.USE_BARREL,
            Command.CLOSE_BARREL, Command.LIST_BARRELS, Command.DROP_BARREL,
            Command.GET_BARREL_CONFIG, Command.SET_BARREL_CONFIG
        ]
        assert len(commands) == len(set(commands))


class TestStatusEnum:
    """Test Status enum values."""

    def test_status_values(self):
        """Test that all status values are correct."""
        assert Status.OK == 0x00
        assert Status.NOT_FOUND == 0x01
        assert Status.ERROR == 0x02
        assert Status.INVALID == 0x03
        assert Status.NO_BARREL == 0x04
        assert Status.BARREL_EXISTS == 0x05
        assert Status.BARREL_NOT_FOUND == 0x06

    def test_all_statuses_unique(self):
        """Test that all status values are unique."""
        statuses = [
            Status.OK, Status.NOT_FOUND, Status.ERROR,
            Status.INVALID, Status.NO_BARREL,
            Status.BARREL_EXISTS, Status.BARREL_NOT_FOUND
        ]
        assert len(statuses) == len(set(statuses))


class TestRequestEncoding:
    """Test request encoding and decoding."""

    def test_encode_decode_get_request(self):
        """Test encoding and decoding a GET request."""
        cmd = Command.GET
        seq = 1
        key = "test_key"
        value = ""

        encoded = encode_request(cmd, seq, key, value)
        decoded_cmd, decoded_seq, decoded_key, decoded_value = decode_request(encoded)

        assert decoded_cmd == cmd
        assert decoded_seq == seq
        assert decoded_key == key
        assert decoded_value == value

    def test_encode_decode_set_request(self):
        """Test encoding and decoding a SET request."""
        cmd = Command.SET
        seq = 42
        key = "mykey"
        value = "myvalue"

        encoded = encode_request(cmd, seq, key, value)
        decoded_cmd, decoded_seq, decoded_key, decoded_value = decode_request(encoded)

        assert decoded_cmd == cmd
        assert decoded_seq == seq
        assert decoded_key == key
        assert decoded_value == value

    def test_encode_decode_delete_request(self):
        """Test encoding and decoding a DELETE request."""
        cmd = Command.DELETE
        seq = 100
        key = "deleteMe"
        value = ""

        encoded = encode_request(cmd, seq, key, value)
        decoded_cmd, decoded_seq, decoded_key, decoded_value = decode_request(encoded)

        assert decoded_cmd == cmd
        assert decoded_seq == seq
        assert decoded_key == key
        assert decoded_value == value

    def test_encode_decode_request_with_sequence(self):
        """Test encoding and decoding a request with sequence number."""
        cmd = Command.GET
        seq = 12345
        key = "test"
        value = ""

        encoded = encode_request(cmd, seq, key, value)
        decoded_cmd, decoded_seq, decoded_key, decoded_value = decode_request(encoded)

        assert decoded_cmd == cmd
        assert decoded_seq == seq
        assert decoded_key == key
        assert decoded_value == value

    def test_encode_decode_request_with_large_key(self):
        """Test encoding and decoding with large key."""
        cmd = Command.SET
        seq = 1
        key = "x" * 1000
        value = "test_value"

        encoded = encode_request(cmd, seq, key, value)
        decoded_cmd, decoded_seq, decoded_key, decoded_value = decode_request(encoded)

        assert decoded_cmd == cmd
        assert decoded_seq == seq
        assert decoded_key == key
        assert decoded_value == value

    def test_encode_decode_request_with_large_value(self):
        """Test encoding and decoding with large value."""
        cmd = Command.SET
        seq = 1
        key = "test_key"
        value = "x" * 10000

        encoded = encode_request(cmd, seq, key, value)
        decoded_cmd, decoded_seq, decoded_key, decoded_value = decode_request(encoded)

        assert decoded_cmd == cmd
        assert decoded_seq == seq
        assert decoded_key == key
        assert decoded_value == value

    def test_encode_request_key_too_large(self):
        """Test that encoding fails with key too large."""
        cmd = Command.SET
        seq = 1
        key = "x" * (MAX_KEY_SIZE + 1)
        value = "test"

        with pytest.raises(ProtocolError) as exc:
            encode_request(cmd, seq, key, value)
        assert "Key too large" in str(exc.value)

    def test_encode_request_value_too_large(self):
        """Test that encoding fails with value too large."""
        cmd = Command.SET
        seq = 1
        key = "test_key"
        value = "x" * (MAX_VALUE_SIZE + 1)

        with pytest.raises(ProtocolError) as exc:
            encode_request(cmd, seq, key, value)
        assert "Value too large" in str(exc.value)

    def test_decode_request_too_short(self):
        """Test that decoding fails with truncated data."""
        data = b"\x01\x00\x00\x00\x01"  # Only 5 bytes, need at least 11

        with pytest.raises(ProtocolError) as exc:
            decode_request(data)
        assert "Request too short" in str(exc.value)

    def test_decode_request_truncated(self):
        """Test that decoding fails with truncated request."""
        # Create a request that says it has a 100-byte key but only provide 10 bytes
        data = b"\x01\x00\x00\x00\x01\x00\x64" + b"x" * 10

        with pytest.raises(ProtocolError) as exc:
            decode_request(data)
        assert "Truncated request" in str(exc.value)

    def test_decode_request_key_too_large(self):
        """Test that decoding fails with key length exceeding max."""
        # Create a request with key length > MAX_KEY_SIZE
        key_len = MAX_KEY_SIZE + 1
        data = b"\x01\x00\x00\x00\x01" + struct.pack(">H", key_len)

        with pytest.raises(ProtocolError) as exc:
            decode_request(data)
        assert "Key too large" in str(exc.value)

    def test_decode_request_invalid_command(self):
        """Test that decoding fails with invalid command."""
        data = b"\xFF\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00"  # Invalid command 0xFF

        with pytest.raises(ProtocolError) as exc:
            decode_request(data)
        assert "Invalid command" in str(exc.value)


class TestResponseEncoding:
    """Test response encoding and decoding."""

    def test_encode_decode_ok_response(self):
        """Test encoding and decoding an OK response."""
        status = Status.OK
        seq = 42
        value = "test_value"

        encoded = encode_response(status, seq, value)
        decoded_status, decoded_seq, decoded_value = decode_response(encoded)

        assert decoded_status == status
        assert decoded_seq == seq
        assert decoded_value == value

    def test_encode_decode_not_found_response(self):
        """Test encoding and decoding a NOT_FOUND response."""
        status = Status.NOT_FOUND
        seq = 1
        value = ""

        encoded = encode_response(status, seq, value)
        decoded_status, decoded_seq, decoded_value = decode_response(encoded)

        assert decoded_status == status
        assert decoded_seq == seq
        assert decoded_value == value

    def test_encode_decode_error_response(self):
        """Test encoding and decoding an ERROR response."""
        status = Status.ERROR
        seq = 100
        value = "error message"

        encoded = encode_response(status, seq, value)
        decoded_status, decoded_seq, decoded_value = decode_response(encoded)

        assert decoded_status == status
        assert decoded_seq == seq
        assert decoded_value == value

    def test_encode_decode_response_with_empty_value(self):
        """Test encoding and decoding response with empty value."""
        status = Status.OK
        seq = 1
        value = ""

        encoded = encode_response(status, seq, value)
        decoded_status, decoded_seq, decoded_value = decode_response(encoded)

        assert decoded_status == status
        assert decoded_seq == seq
        assert decoded_value == ""

    def test_encode_decode_response_with_large_value(self):
        """Test encoding and decoding response with large value."""
        status = Status.OK
        seq = 1
        value = "x" * 10000

        encoded = encode_response(status, seq, value)
        decoded_status, decoded_seq, decoded_value = decode_response(encoded)

        assert decoded_status == status
        assert decoded_seq == seq
        assert decoded_value == value

    def test_encode_response_value_too_large(self):
        """Test that encoding fails with value too large."""
        status = Status.OK
        seq = 1
        value = "x" * (MAX_VALUE_SIZE + 1)

        with pytest.raises(ProtocolError) as exc:
            encode_response(status, seq, value)
        assert "Value too large" in str(exc.value)

    def test_decode_response_too_short(self):
        """Test that decoding fails with truncated data."""
        data = b"\x00\x00\x00\x00\x01"  # Only 5 bytes, need at least 9

        with pytest.raises(ProtocolError) as exc:
            decode_response(data)
        assert "Response too short" in str(exc.value)


class TestProtocolConstants:
    """Test protocol constants."""

    def test_max_key_size(self):
        """Test MAX_KEY_SIZE constant."""
        assert MAX_KEY_SIZE == 65535  # 64KB

    def test_max_value_size(self):
        """Test MAX_VALUE_SIZE constant."""
        assert MAX_VALUE_SIZE == 33554432  # 32MB
