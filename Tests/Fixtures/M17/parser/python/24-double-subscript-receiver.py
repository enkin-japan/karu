EPSILON = 1e-9


def transpose(matrix):
    return [list(col) for col in zip(*matrix)]


def diagonal(matrix, offset=0):
    out = []
    for i in range(len(matrix)):
        out.append(matrix[i][i].‸
    return out


def trace(matrix):
    return sum(diagonal(matrix))
